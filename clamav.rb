#!/usr/bin/env ruby

# This script will execute clamscan using the properties found in
# config/clamav.yml and then store the results in a database which can then
# be referred back to for statistics and diffs.  At the end of each scan
# an HTML report is generated and opened in the default browser.  Before
# each scan, the ClamAV virus definitions are updated.  Run this script
# with "clamav.rb -h" to see the options for installing a LaunchAgent to
# run the script on a daily interval.
#
# Note that if this script is used as the basis for a rails controller that the
# use of log files would need to be updated to be thread-safe (as well as
# analyzing the instance-level memoization).

require 'fileutils'
require 'pathname'
require 'rubygems'
require 'yaml'					# for reading config file
require 'erb'						# for rendering templates
require 'etc'						# to obtain home dir of current user
require 'optparse'  	  # for parsing command line options
require 'optparse/time'
require 'active_record'	# for database access
require 'action_view'		# for DateHelper, NumberHelper, SanitizeHelper, Bytes
require 'active_support/core_ext'

FileUtils.cd(Pathname(__FILE__).parent.realpath)  # enable relative paths (even in require)
$LOAD_PATH << '.'  #allow 1.9.x to use relative requires (since . was removed from $LOAD_PATH)

require 'models/scan'
require 'models/infection'
require 'db/migrate/create_tables'
require 'lib/growl'

include ActionView::Helpers::DateHelper     # to use distance_of_time_in_words
include ActionView::Helpers::NumberHelper   # to use number_with_delimiter, number_to_human_size
include ActionView::Helpers::SanitizeHelper # to use sanitize on logs
include ActiveSupport::CoreExtensions::Numeric::Bytes rescue # to use .megabytes #avoid error in rails 3 - ignored because autoloads


# ===== custom logger =========================================================

# define custom logger (custom format) for use in the run log
class CustomLogger < Logger
  def format_message(severity, timestamp, progname, msg)
    "#{timestamp.to_formatted_s(:db)} #{sprintf("%-6s", severity)} #{msg}\n"
  end
end


# ===== view helpers ==========================================================

# call-seq:
#   hilite_new_infections(file) => "changed" or "unchanged"
#
# Determines whether or not 'file' appeared in the previous scan's infections
# list and returns "unchanged" if it does - otherwise, "changed".  This is
# intended to be used to specify the style surrounding each infection listed
# in the report.  Requires the current scan to be stored in
# Thread.current[:scan] prior to being called.
def hilite_new_infections(file)
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
  scan_value = nil
  prev_scan_value = nil
  changed = false
  if attr.instance_of?(Symbol)
    scan_value = scan.send(attr) rescue nil
    if options[:hilite_changes] == nil || options[:hilite_changes]
      if prev_scan
        prev_scan_value = prev_scan.send(attr.to_sym) rescue nil
        changed = scan_value != prev_scan_value
      end
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
  html += "<div class='comment'>&nbsp;&nbsp;(prev #{prev_scan_value})</div></span>" if changed
  html += "<div class='comment'>#{options[:comment]}</div>" if options[:comment]
  html += "</td></tr></table>"
  return html
end


# call-seq:
#   read_clamscan_logs_as_html => string of html
#
# reads the clamscan log and applies html styles to colorize it
def read_clamscan_logs_as_html
  clamscan_log = "<span class='log_red'>#{IO.read($config["clamscan_stderr"])}</span>"
  clamscan_log += IO.read($config["clamscan_log"])
  clamscan_log.gsub!(Regexp.new("(" + $config["ignores"].join('|') + ")"), '<span class="log_ignore">\1</span>')
  clamscan_log.gsub!(/(^.*: )(.*)( FOUND)$/, '\1<span class="log_red">\2</span>\3')
end


# ===== chart data helpers ====================================================
# Calculate the default chart bar width by finding the oldest completion time
# for the records in the month prior to 'scan' then finding the number of
# seconds between that time and the completion time of the current scan.
# Divide those seconds by the number of scans and then multiply by 1000 to
# convert into JavaScript time.
def chart_bar_width(scan)
  oldest = scan.complete
  rows = scan.get_scans_for_last(1.month)
  rows.each{|row| oldest = row.complete if row.complete < oldest}
  (scan.complete - oldest) / rows.size / 2 * 1000
end


# get list of infection counts for the scans that were performed in the month
# prior to 'scan' as an array of [javascript_time, infections_count] tupples
def infections_count_changes(scan)
  rows = scan.get_scans_for_last(30.days)
  last_count = nil
  rows.collect do |row|
    diff = row.infections_count - last_count rescue 0;
    last_count = row.infections_count;
    [row.complete.to_i * 1000, diff]
  end
end


# get list of known viruses counts for the scans that were performed in the month
# prior to 'scan' as an array of [javascript_time, known_viruses_count] tupples
def known_viruses_count_changes(scan)
  rows = scan.get_scans_for_last(30.days)
  last_count = nil
  rows.collect do |row|
    diff = row.known_viruses - last_count rescue 0;
    last_count = row.known_viruses;
    [row.complete.to_i * 1000, diff]
  end
end


# ===== utility methods =======================================================

# Look for -c, -i, -u, -h, and -v options on command line to configure
# LaunchAgent (like cron) and specify config file to use.  Otherwise, simply
# execute script normally.
def parse_command_line_options
  options = {}
  options[:config] = "config/clamav.yml"  # default
  opts = OptionParser.new
  # define options
  opts.banner = "Usage: clamav.rb [-u] [-i time]"
  opts.on('-c', '--config FILE',
          "Specify config file other than default ",
          "'config/clamav.yml' - use relative path") do |file|
    options[:config] = file
  end
  opts.on('-i', '--install TIME', Time,
          "Install LaunchAgent to run clamav.rb every",
          "day at specified time {eg: 2:30pm}",
          "Try using with --config FILE",
          "Requires RELOGIN") do |time|
    options[:install] = time
  end
  opts.on('-u', '--uninstall', "Uninstall LaunchAgent - requires RELOGIN") do |time|
    options[:uninstall] = true
  end
  opts.on_tail("-h", "--help", "Show this message") {puts opts; exit 0}
  opts.on_tail("-v", "--version", "Show version") {puts "clamav.rb 1.0.0"; exit 0}
  # parse options
  opts.parse!(ARGV)
  options
end


# return Pathname to launch agent script
def launch_agent_path
  Pathname(Etc.getpwuid.dir) + "Library/LaunchAgents/org.danlynn.clamav.plist"
end


# install a new OSX launch agent which will execute this script every day at the
# specified 'time'.  Note that in OSX 10.5, that the user will have to re-login
# in order to activate the launch agent.
def install_launch_agent(config_path, root_dir, time)
  doc = ERB.new(IO.read("config/org.danlynn.clamav.plist.erb")).result(binding)
  File.open(launch_agent_path, 'w') {|f| f.write(doc) }
  `launchctl unload #{launch_agent_path}`
  `launchctl load #{launch_agent_path}`
  puts "*** REMEMBER: The new LaunchAgent which executes clamav.rb on an interval WON'T activate until you logout then log back into this account!"
  exit 0
end


# uninstall the OSX launch agent previously installed by this script
def uninstall_launch_agent
  launch_agent_path.delete
  puts "*** REMEMBER: The LaunchAgent which executes clamav.rb on an interval WILL REMAIN ACTIVE until you logout then log back into this account!"
  exit 0
end


# create missing dirs and delete previous log file
def setup_dir_structure
  # insure that database dir exists so that a new db can be created if necessary
  if $config["database"]["adapter"] == "sqlite3"
    FileUtils.mkpath(File.dirname($config["database"]["database"]))
  end
  # ensure that log dirs exists and last $config["clamscan_log"] is cleared before use
  FileUtils.mkpath(File.dirname($config["run_log"]))
  FileUtils.mkpath(File.dirname($config["clamscan_log"]))
end


# gets the previous (chronologically by complete time) Scan instance to the
# specified 'scan'.  Returns nil if no prev scan.
def prev_scan
  scan_ids = Scan.find(:all, :conditions => ["dir = ?", scan.dir], :order => "complete", :select => "id")
  index = scan_ids.index(scan)
  return nil if index == 0
  Scan.find(scan_ids[index - 1])
end


# read clamav.html.erb file and generate the clamav.html file using the
# results of the scan method.
def generate_scan_report
  freshclam_stderr = IO.read($config["freshclam_stderr"])
  freshclam_stdout = @freshclam_stdout
  template = IO.read("views/clamav.html.erb")
  output = ERB.new(template).result(binding)
  File.open("clamav.html", "w") {|file| file.write(output)}
end


# get list of infections that have been removed since the previous scan
def removed_infections
  return [] unless prev_scan
  current_infections = scan.infections.collect{|infection| infection.file}
  prev_scan.infections.select{|infection| !current_infections.include?(infection.file)}
end


# Updates the virus definitions by running freshclam and captures stdout and
# stderr as for later display in the report.  If no clam_bin_dir specified in
# config yml then simply gen report using previous scan record and logs.
def update_virus_definitions
  unless $config["clam_bin_dir"]
    $logger.info("freshclam: skipped (no clam_bin_dir specified)")
    @freshclam_stdout = ""
    return Scan.find(:last)
  end
  $logger.info("freshclam: update virus definitions: start")
  FileUtils.rm($config["freshclam_stderr"], :force => true)
  @freshclam_stdout = `#{Pathname($config["clam_bin_dir"]) + "freshclam"} 2>#{$config["freshclam_stderr"]}`
  @freshclam_stdout = @freshclam_stdout.gsub(/Downloading .*\[\d{1,3}%\] ?/, "\n").gsub(/(DON'T PANIC!.*?faq {0,1})/, "").gsub("\n\n", "\n")
  $logger.info("freshclam: update virus definitions: complete")
end


# Execute clamscan and pass the data to Scan.create_from_log to store in db.
# If no clam_bin_dir specified in config yml then simply return previous scan
# record and logs.
def scan
  unless $config["clam_bin_dir"]
    $logger.info("clamscan: skipped (no clam_bin_dir specified)")
    return Scan.find(:last)
  end
  $logger.info("clamscan: start")
  start = Time.now
  FileUtils.rm($config["clamscan_log"], :force => true)	# only clean previous logs if about to scan
  FileUtils.rm($config["clamscan_stderr"], :force => true)
  `#{Pathname($config["clam_bin_dir"]) + "clamscan"} -r --quiet --log="#{$config["clamscan_log"]}" --exclude="\.(#{$config["excludes"].join('|')})$" "#{$config["scan_dir"]}" 2>#{$config["clamscan_stderr"]}`
  complete = Time.now
  $logger.info("clamscan: complete")
  Scan.create_from_log(start, complete, $config["scan_dir"], $config["clamscan_log"])
end


# ===== main program ==========================================================
extend ActiveSupport::Memoizable
memoize :scan, :prev_scan, :launch_agent_path

options = parse_command_line_options
if options[:install]
  install_launch_agent(options[:config], Pathname(__FILE__).parent.realpath, options[:install])
elsif options[:uninstall]
  uninstall_launch_agent
end
$config = YAML.load(ERB.new(IO.read(options[:config])).result(binding))
setup_dir_structure
growl = GrowlRubyApi::Growl.new(
    :default_title => "ClamAV",
    :default_image_type => :image_file,
    :default_image => Pathname(__FILE__).parent.realpath + "views/images/ClamAV.png"
)
$logger = ActiveRecord::Base.logger = CustomLogger.new($config["run_log"], 3, 100*1024)  # rotate > 100k keeping last 5
begin 
  ActiveRecord::Base.colorize_logging = false  # prevents weird strings like "[4;36;1m" in log
rescue #support rails 3
  require 'active_support/log_subscriber'
  ActiveSupport::LogSubscriber.colorize_logging = false
end
$logger.info("========== clamav.rb: start ==========")
growl.notify("Started scan")
ActiveRecord::Base.establish_connection($config["database"])
ensure_schema_exists
update_virus_definitions
generate_scan_report
`open "clamav.html"`
$logger.info("========== clamav.rb: complete ==========")
growl.notify("Completed scan")

# TODO: add date that specifies when each infection was first found
