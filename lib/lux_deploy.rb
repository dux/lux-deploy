require 'fileutils'
require 'pathname'
require 'open3'
require 'set'
require 'shellwords'
require 'yaml'

module LuxDeploy
  ROOT ||= Pathname.new(File.expand_path('..', __dir__))
  VERSION ||= File.read(ROOT.join('.version')).strip

  # Branches that select `.env` instead of `.env.staging`.
  MAIN_BRANCHES ||= %w[master main]

  # Server-side conventions. Not config-tunable because doctor and the
  # deploy flow both hardcode these paths in the host setup. A different
  # caddy/systemd layout means a different gem.
  PORT_RANGE  ||= (3010..3990).step(10).to_a
  CADDY_SITES ||= '/etc/caddy/sites'
  SYSTEMD_DIR ||= '/etc/systemd/system'

  # Caddy access-log -> SQLite importer. One host-wide service (IMPORTER_UNIT)
  # runs the bundled script (uploaded to IMPORTER_REMOTE) and scans every app's
  # log dir. Installed by `caddy:log:prepare`.
  IMPORTER_LOCAL    ||= ROOT.join('assets', 'caddy-log-importer.ts').to_s
  IMPORTER_REMOTE   ||= '/usr/local/lib/lux-deploy/caddy-log-importer.ts'
  IMPORTER_UNIT     ||= 'lux-caddylog'
  IMPORTER_RETAIN   ||= 30

  class Error < StandardError
    def to_s
      "ERROR: #{super}"
    end
  end

  # Host-supplied defaults that sit under the user's .yaml. Set once by a
  # wrapping plugin/Hammerfile (e.g. lux-fw seeds 'lux-web' / 'lux-apps'),
  # consumed by Config.new. Empty by default so the gem stays "generic".
  @defaults = {}

  class << self
    attr_reader :defaults

    def set_defaults(hash)
      @defaults = (hash || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end

require_relative 'lux_deploy/config'
require_relative 'lux_deploy/ssh'
require_relative 'lux_deploy/template'
require_relative 'lux_deploy/doctor'
require_relative 'lux_deploy/prepare'
require_relative 'lux_deploy/context'
require_relative 'lux_deploy/manifest'
require_relative 'lux_deploy/remote_state'
require_relative 'lux_deploy/commands'
require_relative 'lux_deploy/hammer'
