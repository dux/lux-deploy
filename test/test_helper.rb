require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'lux_deploy'

module ProjectFixture
  # Run the block inside a throwaway project with a config/deploy/ dir.
  # `files` is name => body, written before the block runs.
  def in_project(files = {})
    Dir.mktmpdir do |dir|
      deploy = File.join(dir, 'config', 'deploy')
      FileUtils.mkdir_p(deploy)
      files.each { |name, body| File.write(File.join(deploy, name), body) }
      Dir.chdir(dir) { yield deploy }
    end
  end
end
