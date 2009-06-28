class Scan < ActiveRecord::Base

  extend ActiveSupport::Memoizable

  has_and_belongs_to_many :infections


  # call-seq:
  #   create_from_log(start, complete, scan_dir, clamscan_log) => new Scan instance
  #
  # Reads the specified 'clamscan_log' and parses it into a new Scan record
  # and saves it to the db.  The other args aren't found in the log so must be
  # passed separately.
  def self.create_from_log(start, complete, scan_dir, clamscan_log)
    summary_log = Pathname(clamscan_log).dirname + "summary_#{Pathname(clamscan_log).basename}"
    `cat "#{clamscan_log}" | egrep -v "#{$config["ignores"].join('|')}" > "#{summary_log}"`
    scan = Scan.new({:start => start, :complete => complete, :dir => scan_dir})
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


  # call-seq:
  #   get_scans_for_last(seconds_ago) => new Scan instance
  #   get_scans_for_last(30.days) => new Scan instance
  #
  # Gets list of Scan instances newer than 'seconds_ago' up to and including
  # the current scan.  Scans newer than the current are NOT included.  
  def get_scans_for_last(seconds_ago)
    Scan.find(:all, :conditions => ["complete > ? and complete <= ?", complete - seconds_ago, complete])
  end

  
  memoize :get_scans_for_last

end
