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
require 'action_view' # for DateHelper, NumberHelper, SanitizeHelper, Bytes

include ActionView::Helpers::DateHelper     # to use distance_of_time_in_words
include ActionView::Helpers::NumberHelper   # to use number_with_delimiter
include ActionView::Helpers::SanitizeHelper # to use sanitize on logs
include ActiveSupport::CoreExtensions::Numeric::Bytes # to use .megabytes



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
    scan.data_scanned = $1.to_f.megabytes
    summary =~ /Data read: ((?:\d|\.)+?) /
    scan.data_read = $1.to_f.megabytes
    summary =~ /Known viruses: (\d+)$/
    scan.known_viruses = $1
    summary =~ /Engine version: ((?:\d|\.)+?)$/
    scan.engine_version = $1
    if scan.infections_count > 0
      summary.scan(/^(.*): (.*) FOUND$/) do |match|
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


# ===== migration =============================================================

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


# ===== custom logger =========================================================

# define custom logger (custom format) for use in the run log
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
  #FileUtils.rm($config["clamscan_log"], :force => true)
  #FileUtils.rm($config["clamscan_stderr"], :force => true)
  FileUtils.rm($config["freshclam_stderr"], :force => true)
end


# gets the previous (chronologically by complete time) Scan instance to the
# specified 'scan'.  Returns nil if no prev scan.
def get_prev_scan(scan)
  scan_ids = Scan.find(:all, :conditions => ["dir = ?", scan.dir], :order => "complete", :select => "id")
  index = scan_ids.index(scan)
  return nil if index == 0
  Scan.find(scan_ids[index - 1])
end


# call-seq:
#   hilite_new_infections(file) => "changed" or "unchanged"
#
# Determines whether or not 'file' appeared in the previous scan's infections
# list and returns "unchanged" if it does - otherwise, "changed".  This is
# intended to be used to specify the style surrounding each infection listed
# in the report.  Requires the current scan to be stored in
# Thread.current[:scan] prior to being called.
def hilite_new_infections(file)
  scan = Thread.current[:scan]
  prev_scan = (Thread.current[:prev_scan] ||= get_prev_scan(scan))
  return "unchanged" if prev_scan.nil? || prev_scan.infections == scan.infections
  Thread.current[:prev_infections] ||= prev_scan.infections.collect{|infection| infection.file}
  return (Thread.current[:prev_infections].include?(file) ? "unchanged" : "changed")
end


# call-seq:
#   field(label, attr, options = {}) => string of html rendering the field
#
# 'options' hash may contain:
#     :hilite_changes => false
#     :view_helper => "number_to_human_size(?, :precision => 2)"
#     :comment => "(#{scan.start.strftime("%I:%M %p")})"
#
# View helper that displays a label and field styled using the div.label,
# div.field, div.comment, .changed, and .unchanged styles.  If the value
# has changed since the last scan then the field is hilited with the
# .changed style and the previous value is displayed in the div.comment
# style to the right.  Requires the current scan to be stored in
# Thread.current[:scan] prior to being called.  Note that if the 'attr'
# arg is NOT a symbol then it is assumed that the value should be displayed
# directly and no attempt is made to access the scan or previous scan or
# any change hiliting.
def field(label, attr, options = {})
  scan = Thread.current[:scan]
  scan_value = nil
  prev_scan_value = nil
  changed = false
  if attr.instance_of?(Symbol)
    scan_value = scan.send(attr) rescue nil
    if options[:hilite_changes] == nil || options[:hilite_changes]
      Thread.current[:prev_scan] ||= get_prev_scan(scan)
      prev_scan_value = Thread.current[:prev_scan].send(attr.to_sym) rescue nil
      changed = scan_value != prev_scan_value
    end
  else
    scan_value = attr # assume attr is ACTUAL value if not a symbol
  end
  if options[:view_helper]
    scan_value = eval(options[:view_helper].sub("?", "scan_value"))
    prev_scan_value = eval(options[:view_helper].sub("?", "prev_scan_value")) if changed
  end
  html = "<table class='line'><tr><td><div class='label'>#{label}:</div></td><td>"
  html += "<span class='changed'>" if changed
  html += "<div class='field'>#{scan_value}</div>"
  html += "</span><div class='comment'>&nbsp;&nbsp;(prev #{prev_scan_value})</div>" if changed
  html += "<div class='comment'>#{options[:comment]}</div>" if options[:comment]
  html += "</td></tr></table>"
end


def read_clamscan_logs_as_html
  clamscan_log = "<span class='log_red'>#{IO.read($config["clamscan_stderr"])}</span>"
  clamscan_log += IO.read($config["clamscan_log"])
  clamscan_log.gsub!(Regexp.new("(" + $config["ignores"].join('|') + ")"), '<span class="log_ignore">\1</span>')
  clamscan_log.gsub!(/(^.*: )(.*)( FOUND)$/, '\1<span class="log_red">\2</span>\3')
end


# read clamav.html.erb file and generate the clamav.html file using the
# specified 'scan'.
def generate_scan_report(scan)
  Thread.current[:scan] = scan
  freshclam_stderr = IO.read($config["freshclam_stderr"])
  freshclam_stdout = @freshclam_stdout
  template = IO.read("views/clamav.html.erb")
  output = ERB.new(template).result(binding)
  File.open("log/clamav.html", "w") {|file| file.write(output)}
end


# updates the virus definitions by running freshclam and captures stdout and 
# stderr as for later display in the report
def update_virus_definitions
  $logger.info("freshclam: update virus definitions: start")
  @freshclam_stdout = `/usr/local/clamXav/bin/freshclam 2>#{$config["freshclam_stderr"]}`
  @freshclam_stdout = @freshclam_stdout.gsub(/Downloading .*\[\d{1,3}%\] {0,1}/, "\n").gsub(/(DON'T PANIC!.*?faq {0,1})/, "").gsub("\n\n", "\n")
  $logger.info("freshclam: update virus definitions: complete")
end


# execute clamscan and pass the data to Scan.create_from_log to store in db
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
#scan = perform_scan
scan = Scan.find(:last)
generate_scan_report(scan)
`open "log/clamav.html"`
$logger.info("========== clamav.rb: complete ==========")
