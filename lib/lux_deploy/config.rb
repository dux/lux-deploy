require 'yaml'

module LuxDeploy
  # Single source of behavior for a deploy. Reads ./config/deploy/.yaml and
  # layers it on top of (a) engine defaults baked into this file and
  # (b) host-supplied defaults from LuxDeploy.defaults (set by a wrapping
  # plugin/Hammerfile, e.g. lux-fw injects 'lux-web' / 'lux-apps' / smoke).
  #
  # Precedence (highest wins): user .yaml > LuxDeploy.defaults > ENGINE_DEFAULTS.
  class Config
    ENGINE_DEFAULTS ||= {
      'service_user'       => 'deployer',
      'remote_base'        => '/home/deployer/apps',
      'service_prefix'     => 'web',
      'job_service_prefix' => nil,
      'smoke_command'      => nil
    }.freeze

    # Keys whose meaning is interpreted in Ruby - excluded from the
    # `template_vars` map so they never become `{{SERVICE_PREFIX}}` etc.
    # `server` is also behavioral (target host) but historically exposed
    # as `{{SERVER}}` in caddy.conf, so it stays in template_vars.
    BEHAVIORAL_KEYS ||= %w[service_user remote_base service_prefix
                           job_service_prefix smoke_command flavor].freeze

    attr_reader :raw

    def self.load
      file = './config/deploy/.yaml'
      raise Error.new("missing #{file} (server: + domain: keys)") unless File.exist?(file)
      data = YAML.safe_load(File.read(file)) || {}
      raise Error.new("#{file} must be a YAML mapping") unless data.is_a?(Hash)
      new(data)
    end

    def initialize(raw)
      stringified = raw.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      @raw = ENGINE_DEFAULTS.merge(LuxDeploy.defaults).merge(stringified)
    end

    def server             ; raw['server'].to_s.strip ; end
    def domain             ; raw['domain'].to_s.strip ; end
    def service_user       ; raw['service_user'].to_s ; end
    def remote_base        ; raw['remote_base'].to_s ; end
    def service_prefix     ; raw['service_prefix'].to_s ; end
    def job_service_prefix ; v = raw['job_service_prefix']; v.to_s.empty? ? nil : v.to_s ; end
    def smoke_command      ; v = raw['smoke_command'];      v.to_s.empty? ? nil : v.to_s ; end

    # Hash of UPPER_SYMBOL => string suitable for Template.render. Drops
    # behavioral keys (service_prefix etc.) so they don't pollute the
    # placeholder namespace. Nil values dropped so doctor's check treats
    # them as missing rather than blank.
    def template_vars
      raw.each_with_object({}) do |(k, v), h|
        next if v.nil?
        next if BEHAVIORAL_KEYS.include?(k.to_s)
        h[k.to_s.upcase.to_sym] = v.to_s
      end
    end
  end
end
