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


# change current dir to that of this ruby script in order to enable relative paths in config
FileUtils.cd(File.dirname(__FILE__))


# load clamav.yml config file into config hash and setup constants
config = YAML.load_file("config/clamav.yml")
CONNECTION = config["database"]
SCAN_DIR = config["scan_dir"]
CLAMSCAN = config["clamscan"]
CLAMSCAN_LOG = config["clamscan_log"]
RUN_LOG = config["run_log"]
EXCLUDES = config["excludes"]
IGNORES = config["ignores"]


# insure that database dir exists so that a new db can be created if necessary
if CONNECTION["adapter"] == "sqlite3"
  FileUtils.mkpath(File.dirname(CONNECTION["database"]))
end


# define active record model
class Scan < ActiveRecord::Base
  has_and_belongs_to_many :infections
  def self.create_from_log(start, complete, log)
    summary_log = Pathname(log).dirname + "summary_#{Pathname(log).basename}"
    `cat "#{log}" | egrep -v "#{IGNORES.join('|')}" > "#{summary_log}"`
    scan = Scan.new({:start => start, :complete => complete})
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


# ensure that log dirs exists and last CLAMSCAN_LOG is cleared before use
FileUtils.mkpath(File.dirname(RUN_LOG))
FileUtils.mkpath(File.dirname(CLAMSCAN_LOG))
FileUtils.rm(CLAMSCAN_LOG, :force => true)


# setup logger (with custom format)
class CustomLogger < Logger
  def format_message(severity, timestamp, progname, msg)
    "#{timestamp.to_formatted_s(:db)} #{sprintf("%-6s", severity)} #{msg}\n"
  end
end
@logger = ActiveRecord::Base.logger = CustomLogger.new(RUN_LOG, 5, 10*1024)  # rotate > 10k keeping last 5
ActiveRecord::Base.colorize_logging = false # prevents weird strings like "[4;36;1m" in log


@logger.info("========== clamav.rb: start ==========")


# establish connection to database
ActiveRecord::Base.establish_connection(CONNECTION)


# create schema if none exists
def ensure_schema_exits
  begin
    @logger.info("Database contains #{Scan.count} scans.")
  rescue ActiveRecord::StatementInvalid => e
    if e.message["Could not find table 'scans'"]  # if no table found
      @logger.info("Initializing db schema")
      ActiveRecord::Schema.define do
        create_table :scans, :force => true do |t|
          t.datetime  :start
          t.datetime  :complete
          t.integer   :infections_count
          t.integer   :dirs_scanned
          t.integer   :files_scanned
          t.integer   :data_scanned
          t.integer   :data_read
          t.integer   :known_viruses
          t.integer   :engine_version
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
# specified 'scan'
def get_prev_scan(scan)
  scan_ids = Scan.find(:all, :order => "complete", :select => "id")
  index = scan_ids.index(scan)
  Scan.find(scan_ids[index - 1])
end


# read clamav.html.erb file and generate the clamav.html file using the
# specified 'scan'.
def generate_scan_report(scan)
  p scan
  p prev_scan = get_prev_scan(scan)
end


def perform_and_log_scan
  @logger.info("clamscan: start")
  start = Time.now
  `#{CLAMSCAN} -r --quiet --log="#{CLAMSCAN_LOG}" --exclude="\.(#{EXCLUDES.join('|')})$" "#{SCAN_DIR}"`
  complete = Time.now
  @logger.info("clamscan: complete")
  scan = Scan.create_from_log(start, complete, CLAMSCAN_LOG)
  #scan = Scan.find(:last)
end


ensure_schema_exits
scan = perform_and_log_scan
html = generate_scan_report(scan)


@logger.info("========== clamav.rb: complete ==========")
