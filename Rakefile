require 'rake'
# require 'rake/testtask'
# require 'rake/rdoctask'
require 'pathname'
require 'tmpdir'


# Deletes log dir, files in db dir, and clamav.html file
def clean(root_dir)
	root_dir = Pathname(root_dir)	# ensure root_dir is a Pathname instance
	# delete log dir
	FileUtils.rm_r((root_dir + "log").to_s) rescue # ignore error when already deleted
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


desc "Copies current dir to temp dir then cleans for zip then zips to current dir"
task :zip do
	orig_root_dir = Pathname(__FILE__).parent
	temp_root_dir = Pathname(Dir.tmpdir) + orig_root_dir.basename
	`cp -R "#{orig_root_dir}" "#{temp_root_dir}"`
	puts "before:\n" + `ls -la "#{temp_root_dir}"`
	clean(temp_root_dir)
	# delete .git dir
	FileUtils.rm_r((temp_root_dir + ".git").to_s) rescue # ignore error when already deleted
	# delete .gitignore file
	(temp_root_dir + ".gitignore").delete
	# delete Rakefile file
	(temp_root_dir + "Rakefile").delete
	puts "------------\nafter:\n" + `ls -la "#{temp_root_dir}"`

	Rake::PackageTask.new("clamav_report", "1.0.0") do |p|
    p.need_zip = true
    p.package_files.include("#{temp_root_dir}/**/*")
  end

	FileUtils.rm_r((temp_root_dir).to_s)
end