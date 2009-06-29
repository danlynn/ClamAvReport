require 'rake'
# require 'rake/testtask'
# require 'rake/rdoctask'
require 'pathname'


# Deletes log dir, files in db dir, and clamav.html file
def clean(root_dir)
	root_dir = Pathname(root_dir)	# ensure root_dir is a Pathname instance
	# delete log dir
	FileUtils.rm_r((root_dir + "log").to_s) rescue # ignore error when already deleted
	# delete all files in db dir
	(root_dir + "db").children.each{|f| f.delete if f.file?}
	# delete clamav.html report
	(root_dir + "clamav.html").delete
end


# Deletes log dir, files in db dir, and clamav.html file, .git dir, .gitignore, Rakefile
def clean_for_zip(root_dir)
	root_dir = Pathname(root_dir)	# ensure root_dir is a Pathname instance
	clean(root_dir)
	# delete .git dir
	FileUtils.rm_r((root_dir + ".git").to_s) rescue # ignore error when already deleted
	# delete .gitignore file
	(root_dir + ".gitignore").delete
	# delete Rakefile file
	(root_dir + "Rakefile").delete
end


desc "Deletes log dir, files in db dir, and clamav.html file"
task :clean do
	clean(Pathname(__FILE__).parent)
end

