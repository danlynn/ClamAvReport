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
    summary = IO.read(summary_log)
    summary =~ /Infected files: (\d+)$/
    puts "infections_count = #{$1}"
    summary =~ /Scanned directories: (\d+)$/
    puts "dirs_scanned = #{$1}"
    summary =~ /Scanned files: (\d+)$/
    puts "files_scanned = #{$1}"
    summary =~ /Data scanned: ((?:\d|\.)+?) /
    puts "data_scanned = #{$1}"
    summary =~ /Data read: ((?:\d|\.)+?) /
    puts "data_read = #{$1}"
    summary =~ /Known viruses: (\d+)$/
    puts "known_viruses = #{$1}"
    summary =~ /Engine version: ((?:\d|\.)+?)$/
    puts "engine_version = #{$1}"
    #if infections_count > 0 then parse infections_list
    # delete temp file
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
logger = ActiveRecord::Base.logger = CustomLogger.new(RUN_LOG, 5, 10*1024)  # rotate > 10k keeping last 5
ActiveRecord::Base.colorize_logging = false # prevents weird strings like "[4;36;1m" in log


logger.info("========== clamav.rb: start ==========")


# establish connection to database
ActiveRecord::Base.establish_connection(CONNECTION)


# create schema if none exists
begin
  logger.info("Database contains #{Scan.count} scans.")
rescue ActiveRecord::StatementInvalid => e
  if e.message["Could not find table 'scans'"]  # if no table found
    logger.info("Initializing db schema")
    ActiveRecord::Schema.define do
      create_table :scans, :force => true do |t|
        t.column :start,            :datetime
        t.column :complete,         :datetime
        t.column :infections_count, :integer
        t.column :dirs_scanned,     :integer
        t.column :files_scanned,    :integer
        t.column :data_scanned,     :integer
        t.column :data_read,        :integer
        t.column :known_viruses,    :integer
        t.column :engine_version,   :integer
      end
      create_table :infections, :force => true do |t|
        t.column :file,             :text
        t.column :infection,        :text
      end
      create_table :scans_infections, :force => true do |t|
        t.column :scan_id,          :integer
        t.column :infection_id,     :integer
      end
    end
  end
end


def generate_scan_report(scan)

end


logger.info("clamscan: start")
start = Time.now
`#{CLAMSCAN} -r --quiet --log="#{CLAMSCAN_LOG}" --exclude="\.(#{EXCLUDES.join('|')})$" "#{SCAN_DIR}"`
complete = Time.now
logger.info("clamscan: complete")


Scan.create_from_log(start, complete, CLAMSCAN_LOG)


logger.info("========== clamav.rb: complete ==========")
