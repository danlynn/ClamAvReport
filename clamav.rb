#!/usr/bin/env ruby

# This script will execute clamscan using the properties found in
# config/clamav.yml and then store the results in a database which can then
# be referred back to for statistics and diffs.  At the end of each scan
# an HTML report is generated and opened in the default browser.

require 'rubygems'
require 'yaml'
require 'fileutils'
require 'active_record'
require 'pathname'
require 'erb'
require 'action_view' # for DateHelper

include ActionView::Helpers::DateHelper # to use distance_of_time_in_words



# ===== models ================================================================

# define active record model
class Scan < ActiveRecord::Base
  has_and_belongs_to_many :infections
  def self.create_from_log(start, complete, dir, log)
    summary_log = Pathname(log).dirname + "summary_#{Pathname(log).basename}"
    `cat "#{log}" | egrep -v "#{$config["ignores"].join('|')}" > "#{summary_log}"`
    scan = Scan.new({:start => start, :complete => complete, :dir => dir})
    summary = IO.read(summary_log)
    summary =~ /Infected files: (\d+)$/
    scan.infections_count = $1
    summary =~ /Scanned directories: (\d+)$/
    scan.dirs_scanned = $1
    summary =~ /Scanned files: (\d+)$/
    scan.files_scanned = $1
    summary =~ /Data scanned: ((?:\d|\.)+?) /
    scan.data_scanned = $1
    summary =~ /Data read: ((?:\d|\.)+?) /
    scan.data_read = $1
    summary =~ /Known viruses: (\d+)$/
    scan.known_viruses = $1
    summary =~ /Engine version: ((?:\d|\.)+?)$/
    scan.engine_version = $1
    if scan.infections_count > 0
      summary.scan(/^(.*): (.*) FOUND$/) do |match|
        puts "file=#{$1}\ninfection=#{$2}\n\n"
        scan.infections << (Infection.find_by_file_and_infection($1, $2) || Infection.new({:file => $1, :infection => $2}))
      end
    end
    scan.save
    return scan
    # delete temp file?
  end
end


class Infection < ActiveRecord::Base
  has_and_belongs_to_many :scans
end


# ===== custom logger =========================================================

# setup logger (with custom format)
class CustomLogger < Logger
  def format_message(severity, timestamp, progname, msg)
    "#{timestamp.to_formatted_s(:db)} #{sprintf("%-6s", severity)} #{msg}\n"
  end
end


# ===== utility methods =======================================================

# create missing dirs and delete previous log file
def setup_and_clean_dir_structure
  # insure that database dir exists so that a new db can be created if necessary
  if $config["database"]["adapter"] == "sqlite3"
    FileUtils.mkpath(File.dirname($config["database"]["database"]))
  end
  # ensure that log dirs exists and last $config["clamscan_log"] is cleared before use
  FileUtils.mkpath(File.dirname($config["run_log"]))
  FileUtils.mkpath(File.dirname($config["clamscan_log"]))
  FileUtils.rm($config["clamscan_log"], :force => true)
  FileUtils.rm($config["clamscan_stderr"], :force => true)
  FileUtils.rm($config["freshclam_stderr"], :force => true)
end


# create schema if none exists
def ensure_schema_exits
  begin
    $logger.info("Database contains #{Scan.count} scans.")
  rescue ActiveRecord::StatementInvalid => e
    if e.message["Could not find table 'scans'"]  # if no table found
      $logger.info("Initializing db schema")
      ActiveRecord::Schema.define do
        create_table :scans, :force => true do |t|
          t.datetime  :start
          t.datetime  :complete
          t.integer   :infections_count
          t.string    :dir
          t.integer   :dirs_scanned
          t.integer   :files_scanned
          t.float     :data_scanned
          t.float     :data_read
          t.integer   :known_viruses
          t.string    :engine_version
        end
        create_table :infections, :force => true do |t|
          t.text      :file
          t.text      :infection
        end
        create_table :infections_scans, :id => false, :force => true do |t|
          t.integer   :scan_id
          t.integer   :infection_id
        end
      end
    end
  end
end


# gets the previous (chronologically by complete time) Scan instance to the
# specified 'scan'.  Returns nil if no prev scan.
def get_prev_scan(scan)
  scan_ids = Scan.find(:all, :order => "complete", :select => "id")
  index = scan_ids.index(scan)
  return nil if index == 0
  Scan.find(scan_ids[index - 1])
end


# read clamav.html.erb file and generate the clamav.html file using the
# specified 'scan'.
def generate_scan_report(scan)
  prev_scan = get_prev_scan(scan)
  freshclam_stderr = IO.read($config["freshclam_stderr"])
  freshclam_stdout = @freshclam_stdout
  template = IO.read("views/clamav.html.erb")
  output = ERB.new(template).result(binding)
  File.open("log/clamav.html", "w") {|file| file.write(output)}
end


def update_virus_definitions
  $logger.info("freshclam: update virus definitions: start")
  @freshclam_stdout = `/usr/local/clamXav/bin/freshclam 2>#{$config["freshclam_stderr"]}`
  @freshclam_stdout = @freshclam_stdout.gsub(/Downloading .*\[\d{1,3}%\] {0,1}/, "\n").gsub(/(DON'T PANIC!.*?faq {0,1})/, "").gsub("\n\n", "\n")
  $logger.info("freshclam: update virus definitions: complete")
end


def perform_scan
  $logger.info("clamscan: start")
  start = Time.now
  # TODO capture clamscan sysout / syserr output - possibly look for engine update warnings
  `#{$config["clamscan"]} -r --quiet --log="#{$config["clamscan_log"]}" --exclude="\.(#{$config["excludes"].join('|')})$" "#{$config["scan_dir"]}" 2>#{$config["clamscan_stderr"]}`
  complete = Time.now
  $logger.info("clamscan: complete")
  Scan.create_from_log(start, complete, $config["scan_dir"], $config["clamscan_log"])
end


# ===== main program ==========================================================

FileUtils.cd(File.dirname(__FILE__))  # enable relative paths in config

$config = YAML.load_file("config/clamav.yml")
setup_and_clean_dir_structure
$logger = ActiveRecord::Base.logger = CustomLogger.new($config["run_log"], 5, 10*1024)  # rotate > 10k keeping last 5
ActiveRecord::Base.colorize_logging = false # prevents weird strings like "[4;36;1m" in log
$logger.info("========== clamav.rb: start ==========")
ActiveRecord::Base.establish_connection($config["database"])
ensure_schema_exits
update_virus_definitions
scan = perform_scan
#scan = Scan.find(:last)
generate_scan_report(scan)
`open "log/clamav.html"`
$logger.info("========== clamav.rb: complete ==========")
