# To clean current project run: 
# 		rake clean
#
# To generate a pkg/clamav_report-1.0.0.zip:
# 		rake package
#
# To list all rake tasks:
# 		rake -T

require 'rake'
require 'rake/packagetask'
# require 'rake/testtask'
# require 'rake/rdoctask'
require 'pathname'


# Deletes log dir, files in db dir, and clamav.html file
def clean(root_dir)
	# delete log dir
	FileUtils.rm_r((root_dir + "log").to_s) rescue # ignore error when already deleted
    # delete pkg dir (from rake package)
    FileUtils.rm_r((root_dir + "pkg").to_s) rescue # ignore error when already deleted
	# delete all files in db dir
	(root_dir + "db").children.each{|f| puts "=== #{f.basename} : #{f.file?}"}
	(root_dir + "db").children.each{|f| f.delete if f.file?}
	# delete clamav.html report
	(root_dir + "clamav.html").delete
end


desc "Deletes log dir, files in db dir, and clamav.html file"
task :clean do
	clean(Pathname(__FILE__).parent)
end


# Creates a zip of project suitable for execution - but not development
Rake::PackageTask.new("ClamAV-Scan_Report", "1.0.0") do |p|
	p.need_zip = true
	p.package_files.include("config/clamav.yml")
	p.package_files.include("db/migrate/*")
	p.package_files.include("models/*.rb")
	p.package_files.include("views/**/*")
	p.package_files.include("clamav.rb")
end
