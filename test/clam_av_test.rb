require "test/unit"
require 'yaml'
require 'erb'
require 'fileutils'
require 'pathname'
require 'etc' # needed by user home dir determination in config/clamav.yml files

class ClamAvTest < Test::Unit::TestCase

  # Called before every test method runs. Can be used
  # to set up fixture information.
  def setup
    FileUtils.cd(Pathname(__FILE__).parent.parent.realpath)  # enable relative paths (even in require)
  end

  # Called after every test method runs. Can be used to tear
  # down fixture information.

  def teardown
    # Do nothing
  end

  def test_clam_bin_dir
    $config = YAML.load(ERB.new(IO.read('config/clamav.yml')).result(binding))
    unless $config['clam_bin_dir']
      fail("Specified config.yml clam_bin_dir is empty. Only tests can be run without specifying the clam_bin_dir.")
    end
  end

  def test_clamav_installed
    $config = YAML.load(ERB.new(IO.read('config/clamav.yml')).result(binding))
    unless File.exists?($config['clam_bin_dir'])
      fail("Specified config.yml clam_bin_dir does not exist. Does clamav needs to be installed?")
    end
  end
  
  def run_report_in_test_dir(dir_name)
    `ruby clamav.rb --config test/#{dir_name}/config/clamav.yml`
    actual = File.read('clamav.html')
    expected = File.read("test/#{dir_name}/clamav.expected_output.html")
    unless actual == expected
      `opendiff test/#{dir_name}/clamav.expected_output.html clamav.html &` rescue nil
      fail("test/#{dir_name} generated a clamav.html which failed to match test/#{dir_name}/clamav.expected_output.html")
    end
  end
  
  def test_report1
    run_report_in_test_dir('test1')
  end

  def test_report2
    run_report_in_test_dir('test2')
  end

  def test_report3
    run_report_in_test_dir('test3')
  end

end
