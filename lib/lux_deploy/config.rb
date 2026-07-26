require 'yaml'

module LuxDeploy
  # Single source of behavior for a deploy. Reads ./config/deploy/.yaml and
  # layers it on top of (a) engine defaults baked into this file and
  # (b) host-supplied defaults from LuxDeploy.defaults (set by a wrapping
  # plugin/Hammerfile, e.g. lux-fw injects 'lux-web' / 'lux-apps').
  #
  # Precedence (highest wins): config/deploy/src > user .yaml >
  # LuxDeploy.defaults > ENGINE_DEFAULTS.
  class Config
    ENGINE_DEFAULTS ||= {
      'service_user'   => 'deployer',
      'remote_base'    => '/home/deployer/apps',
      'service_prefix' => 'web',
      'on_fail'        => 'keep',
      'health'         => true,
      'boot_timeout'   => 30,
      'health_path'    => nil,
      'branch_domain'  => '{{GIT_BRANCH_SLUG}}.{{APP_DOMAIN}}'
    }.freeze

    # What `up` does when a post-swap step fails. `keep` leaves the new release
    # live and fails loudly (the historical behavior); `rollback` restores the
    # previous release. Opt-in, because silent auto-rollback is exactly the kind
    # of magic this gem avoids.
    ON_FAIL_MODES ||= %w[keep rollback].freeze

    # Keys whose meaning is interpreted in Ruby - excluded from the
    # `template_vars` map so they never become `{{SERVICE_PREFIX}}` etc.
    # `server` is also behavioral (target host) but historically exposed
    # as `{{SERVER}}` in caddy.conf, so it stays in template_vars.
    BEHAVIORAL_KEYS ||= %w[service_user remote_base service_prefix on_fail
                           health boot_timeout health_path branch_domain src].freeze

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

    # Local rsync source. A separate, non-secret file can override the value
    # from .yaml so deploy artifact paths can be tracked safely. Trailing slash
    # is forced so rsync ships the dir's contents, not the dir itself.
    def src
      file = './config/deploy/src'
      v = File.file?(file) ? File.read(file).strip : ''
      v = raw['src'].to_s.strip if v.empty?
      v = './' if v.empty?
      v.end_with?('/') ? v : v + '/'
    end
    # 'keep' (default) or 'rollback'. Validated here so a typo fails at load
    # time rather than silently degrading to the default after a bad deploy.
    def on_fail
      v = raw['on_fail'].to_s.strip
      v = 'keep' if v.empty?
      return v if ON_FAIL_MODES.include?(v)
      raise Error.new("config/deploy/.yaml: on_fail must be one of #{ON_FAIL_MODES.join(', ')} (got #{v.inspect})")
    end

    def rollback_on_fail? = on_fail == 'rollback'

    # The port contract, enforced: after the restart lux-deploy waits for the
    # app to bind the PORT it was handed. `health: false` turns the wait off
    # (and config/deploy/health.sh replaces it entirely).
    def health? = raw['health'] != false

    def boot_timeout
      v = raw['boot_timeout'].to_i
      v.positive? ? v : 30
    end

    # Hostname pattern for a non-main branch. Rendered with GIT_BRANCH,
    # GIT_BRANCH_UNDERSCORE, GIT_BRANCH_SLUG and APP_DOMAIN - so
    # '{{GIT_BRANCH_SLUG}}.staging.{{APP_DOMAIN}}' groups every branch under a
    # single wildcard cert, if you would rather have that.
    def branch_domain
      v = raw['branch_domain'].to_s.strip
      v.empty? ? ENGINE_DEFAULTS['branch_domain'] : v
    end

    # Optional HTTP probe on top of the port wait, e.g. `health_path: /up`.
    def health_path
      v = raw['health_path'].to_s.strip
      return nil if v.empty?
      v.start_with?('/') ? v : "/#{v}"
    end

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
