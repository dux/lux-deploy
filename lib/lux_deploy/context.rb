module LuxDeploy
  # Bag of resolved state for a single command invocation.
  class Context
    # A deployable unit. systemd.service is the web service (caddy-fronted);
    # any other config/deploy/<name>.service becomes <prefix>-<app>-<name>.
    Service ||= Struct.new(:name, :template, :artifact, :unit, :web)

    attr_reader :host, :ssh, :branch, :branch_slug, :app, :app_dir, :app_domain,
                :domain_list, :config_dir, :env_template_name, :config, :templates_dir
    attr_accessor :ports, :domain, :rendered

    # True on master/main - the branch whose deploy serves `domain:` verbatim.
    def main_branch? = @main

    # Parent of every branch's dir: <remote_base>/<app_domain>/. Only pruned
    # by destroy, never created or removed on its own.
    def app_root = File.join(config.remote_base, @app_domain)

    # Domains this deploy serves, split out of domain_list.
    def domains = @domain_list.split(',').map(&:strip).reject(&:empty?)

    # Primary web port. Convenience for the manifest / done line; the full
    # set (PORT, PORT_*) lives in #ports.
    def port
      ports && ports[:PORT]
    end

    def ruby_path
      @ruby_path ||= detect_ruby_path
    end

    # Service user's home. Every remote step runs via `sudo -iu <user>`, so
    # this is where mise/bun land. Debian useradd -m convention.
    def service_home = "/home/#{config.service_user}"

    # All template-substitution vars come from two places: git-derived and
    # yaml. Engine-dynamic vars (PORT, DIR, RUBY, RUBY_DIR) layer on top in
    # render_artifacts since they are only known after server probe. The
    # rendered .env never feeds back into this namespace - .env is a
    # runtime-only file the app reads at boot.
    def base_vars
      Template.git_vars.merge(config.template_vars).merge(
        APP: @app,
        APP_UNDERSCORE: @app.gsub(/[^A-Za-z0-9]+/, '_'),
        APP_DOMAIN: @app_domain,
        # Overrides the raw yaml value: on a branch this is the branch host, so
        # caddy.conf needs no branch awareness of its own.
        DOMAIN: @domain_list,
        HASH: domain_hash,
        TAG: domain_tag
      )
    end

    def domain_hash
      require 'digest'
      "h#{Digest::SHA256.hexdigest(@domain.to_s)[0, 6]}"
    end

    def domain_tag
      require 'digest'
      "s#{Digest::SHA256.hexdigest(@domain.to_s)[0, 5]}"
    end

    def self.read_host(opts)
      override = opts[:server]
      return override.to_s.strip if override && !override.to_s.strip.empty?
      Config.load.server.tap do |host|
        raise Error.new("config/deploy/.yaml: 'server:' is empty") if host.empty?
      end
    end

    def self.build(opts)
      ctx = new
      ctx.send(:resolve!, opts)
      ctx
    end

    # Raw template body, or nil when the file exists in neither the app's
    # config/deploy nor the plugin templates_dir. Non-raising twin of
    # read_template - used for cheap scans (port keys, {{RUBY}} presence).
    def template_source(name)
      local = File.join(@config_dir, name)
      return File.read(local) if File.exist?(local)
      if templates_dir
        shipped = File.join(templates_dir, name)
        return File.read(shipped) if File.exist?(shipped)
      end
      nil
    end

    # Look up a template by name. Apps override individual files by dropping
    # them in ./config/deploy/<name>; if missing, fall back to the host-
    # supplied templates_dir (set via Hammer.register), if any.
    def read_template(name)
      template_source(name) or
        raise Error.new("template not found: #{name} (looked in #{@config_dir}" \
                        "#{templates_dir ? " and #{templates_dir}" : ''})")
    end

    # Services discovered from config/deploy/*.service. systemd.service is
    # always present (web, caddy front); every other file is an extra unit.
    # A leading "!" disables a file (e.g. !job.service) - lux-deploy ignores
    # it everywhere (not a service, not rsync'd). Pure filesystem lookup -
    # no ssh - so commands that never render (destroy, server:*) can use it.
    def services
      @services ||= begin
        prefix = config.service_prefix
        list = [Service.new('web', 'systemd.service', 'systemd.service',
                            "#{prefix}-#{app}", true)]
        Dir.children(@config_dir).select { |f| f.end_with?('.service') && !f.start_with?('!') }.sort.each do |f|
          next if f == 'systemd.service'
          name = f.sub(/\.service\z/, '')
          list << Service.new(name, f, "systemd.#{name}.service",
                              "#{prefix}-#{app}-#{name}", false)
        end
        list
      end
    end

    # True when any rendered template references {{RUBY}}/{{RUBY_DIR}}. Gates
    # the (ssh) ruby probe so a Go/Python app whose unit runs a built binary
    # deploys without a ruby on the box.
    def ruby_used?
      return @ruby_used unless @ruby_used.nil?
      names = (['caddy.conf', env_template_name] + services.map(&:template)).uniq
      @ruby_used = names.any? { |n| (s = template_source(n)) && s.include?('{{RUBY') }
    end

    private

    def resolve!(opts)
      @config_dir = './config/deploy'
      raise Error.new("missing #{@config_dir}/ directory") unless Dir.exist?(@config_dir)

      @config = Config.load
      @config.on_fail # validate now: inside the failure handler is too late to learn about a typo
      @templates_dir = opts[:templates_dir]

      @host = (opts[:server].to_s.strip.empty? ? @config.server : opts[:server]).to_s.strip
      raise Error.new("no server set (.yaml 'server:' or --server)") if @host.empty?

      @ssh         = SSH.new(@host, service_user: @config.service_user, dry_run: opts[:dry_run] || false)
      @branch      = Template.git_vars[:GIT_BRANCH]
      @branch_slug = Template.slug(@branch)
      raise Error.new("branch #{@branch.inspect} has no usable slug") if @branch_slug.empty?
      @main = LuxDeploy::MAIN_BRANCHES.include?(@branch)
      @env_template_name = pick_env_template

      # The app's identity domain, independent of branch: first comma-split
      # segment of yaml `domain:`, with any leading "*." stripped.
      raw = @config.domain.to_s
      raise Error.new("config/deploy/.yaml: 'domain:' is empty") if raw.strip.empty?
      @app_domain = raw.split(',').first.to_s.strip.sub(/^\*\./, '')
      raise Error.new('domain resolved to empty') if @app_domain.empty?

      # What this deploy serves. main gets `domain:` verbatim (multi-host
      # allowed); every other branch gets its own host, so two branches never
      # claim the same site address in caddy.
      @domain_list = @main ? raw.strip : render_branch_domain
      @domain      = @domain_list.split(',').first.to_s.strip.sub(/^\*\./, '')

      # Identity vs location. The slug names the systemd unit and the caddy
      # file, both of which live in flat directories; the app dir nests so
      # every branch of one app sits under a single parent.
      @app     = "#{@app_domain}-#{@branch_slug}"
      @app_dir = File.join(@config.remote_base, @app_domain, @branch_slug)
    end

    # `branch_domain:` is rendered against a deliberately small var set - it
    # resolves before the full namespace exists, and Template.render raises on
    # anything else, which is the error message we want.
    def render_branch_domain
      Template.render(@config.branch_domain,
                      Template.git_vars.merge(APP_DOMAIN: @app_domain)).strip
    rescue Error => e
      raise Error.new("config/deploy/.yaml branch_domain: #{e.message.sub(/\AERROR: /, '')} " \
                      '(available: GIT_BRANCH, GIT_BRANCH_UNDERSCORE, GIT_BRANCH_SLUG, APP_DOMAIN)')
    end

    # First hit wins: an exact per-branch file, then its slugged form, then
    # main-vs-everything-else. `.env.local` is never a branch template - it is
    # the name of the server-side overlay, and a branch called "local" must
    # not hijack it.
    def env_template_candidates
      list = [".env.#{@branch}", ".env.#{@branch_slug}"]
      list << '.env.main' if @main
      list << '.env.default'
      list.uniq.reject { |n| n == '.env.local' }
    end

    def pick_env_template
      candidates = env_template_candidates
      candidates.each { |name| return name if template_source(name) }
      raise Error.new("no env template for branch #{@branch}; looked for #{candidates.join(', ')}")
    end

    def detect_ruby_path
      return "#{service_home}/.local/share/mise/installs/ruby/CURRENT/bin/ruby" if @ssh.dry_run
      out = @ssh.run(<<~SH, as: :service, allow_fail: true)
        ls -td ~/.local/share/mise/installs/ruby/*/bin/ruby 2>/dev/null | head -n1 || which ruby
      SH
      path = out.lines.find { |l| l.strip.start_with?('/') }&.strip
      raise Error.new("no ruby found on remote (mise not installed for #{config.service_user}?)") if path.to_s.empty?
      path
    end
  end
end
