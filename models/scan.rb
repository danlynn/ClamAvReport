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
