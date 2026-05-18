version = File.read(File.expand_path('.version', File.dirname(__FILE__))).strip

Gem::Specification.new 'lux-deploy', version do |s|
  s.summary     = 'Stupid-simple SSH/rsync deploy with pluggable flavors'
  s.description = 'Caddy + systemd + atomic-release deploys over SSH. Lux is one flavor; bring your own adapter for Rails, static sites, anything else.'
  s.authors     = ['Dino Reic']
  s.email       = 'rejotl@gmail.com'
  s.files       = Dir['./lib/**/*.rb'] + Dir['./templates/**/*'] + ['./.version', './README.md', './bin/lux-deploy', './Hammerfile']
  s.bindir      = 'bin'
  s.executables = ['lux-deploy']
  s.homepage    = 'https://github.com/dux/lux-deploy'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.7'

  s.add_dependency 'lux-hammer'
end
