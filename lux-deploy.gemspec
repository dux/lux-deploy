version = File.read(File.expand_path('.version', File.dirname(__FILE__))).strip

# Templates are dotfiles (.yaml, .env, .env.staging) and Dir[] skips those
# without FNM_DOTMATCH - which silently shipped a gem whose `app:init` produced
# an unusable config/deploy/.
templates = Dir.glob('./templates/**/*', File::FNM_DOTMATCH).select { |f| File.file?(f) }

Gem::Specification.new 'lux-deploy', version do |s|
  s.summary     = 'Stupid-simple SSH/rsync deploy: Caddy + systemd + atomic releases'
  s.description = 'Deploy over SSH with rsync, Caddy and systemd. No Docker, no registry, no adapter classes - a file in config/deploy/ is the contract.'
  s.authors     = ['Dino Reic']
  s.email       = 'rejotl@gmail.com'
  s.files       = Dir['./lib/**/*.rb'] + templates + Dir['./assets/**/*'] + Dir['./test/**/*.rb'] +
                  ['./.version', './README.md', './bin/lux-deploy', './Hammerfile', './Rakefile']
  s.bindir      = 'bin'
  s.executables = ['lux-deploy']
  s.homepage    = 'https://github.com/dux/lux-deploy'
  s.license     = 'MIT'

  # commands.rb uses an endless method definition.
  s.required_ruby_version = '>= 3.0'

  s.add_dependency 'lux-hammer'
end
