module LuxDeploy
  # Bag of resolved state for a single command invocation.
  class Context
    attr_reader :host, :ssh, :branch, :app, :app_dir, :config_dir,
                :env_template_name, :config, :templates_dir
    attr_accessor :port, :domain, :rendered

    def ruby_path
      @ruby_path ||= detect_ruby_path
    end

    # Base vars available to every template before .env is rendered:
    # git-derived + yaml. PORT/DIR/RUBY/RUBY_DIR are layered on top in
    # render_artifacts since they are only known after server probe.
    def base_vars
      Template.git_vars.merge(config.template_vars)
    end

    def self.read_host(opts)
      override = opts[:server]
      return override.to_s.strip if override && !override.to_s.strip.empty?
      Config.load.server.tap do |host|
        raise Error.new("config/deploy/.yaml: 'server:' is empty") if host.empty?
      end
    end

    def self.build(opts, render: true)
      ctx = new
      ctx.send(:resolve!, opts)
      ctx
    end

    # Look up a template by name. Apps override individual files by dropping
    # them in ./config/deploy/<name>; if missing, fall back to the host-
    # supplied templates_dir (set via Hammer.register), if any.
    def read_template(name)
      local = File.join(@config_dir, name)
      return File.read(local) if File.exist?(local)
      if templates_dir
        shipped = File.join(templates_dir, name)
        return File.read(shipped) if File.exist?(shipped)
      end
      raise Error.new("template not found: #{name} (looked in #{@config_dir}" \
                      "#{templates_dir ? " and #{templates_dir}" : ''})")
    end

    def job_template?
      return false unless config.job_service_prefix
      File.exist?(File.join(@config_dir, 'job.service'))
    end

    private

    def resolve!(opts)
      @config_dir = './config/deploy'
      raise Error.new("missing #{@config_dir}/ directory") unless Dir.exist?(@config_dir)

      @config = Config.load
      @templates_dir = opts[:templates_dir]

      @host = (opts[:server].to_s.strip.empty? ? @config.server : opts[:server]).to_s.strip
      raise Error.new("no server set (.yaml 'server:' or --server)") if @host.empty?

      @ssh    = SSH.new(@host, service_user: @config.service_user, dry_run: opts[:dry_run] || false)
      @branch = Template.git_vars[:GIT_BRANCH]
      @env_template_name = LuxDeploy::MAIN_BRANCHES.include?(@branch) ? '.env' : '.env.staging'

      # App slug = result of rendering .env's DOMAIN, falling back to
      # yaml's `domain:` when .env doesn't redefine it. Render with stubs
      # for PORT/DIR/RUBY since we just need the DOMAIN line.
      preview_vars = base_vars.merge(PORT: 0, DIR: '/tmp/preview', RUBY: 'stub', RUBY_DIR: 'stub')
      preview = Template.render(read_template(@env_template_name), preview_vars)
      env = Template.parse_env(preview)
      raw = (env[:DOMAIN] || @config.domain).to_s
      raise Error.new("no domain (.yaml 'domain:' or DOMAIN= in #{@env_template_name})") if raw.strip.empty?
      domain = raw.split(',').first.to_s.strip.sub(/^\*\./, '')
      raise Error.new('domain resolved to empty') if domain.empty?
      @app     = domain
      @domain  = domain
      @app_dir = File.join(@config.remote_base, domain)
    end

    def detect_ruby_path
      return "/home/#{config.service_user}/.local/share/mise/installs/ruby/CURRENT/bin/ruby" if @ssh.dry_run
      out = @ssh.run(<<~SH, as: :service, allow_fail: true)
        ls -td ~/.local/share/mise/installs/ruby/*/bin/ruby 2>/dev/null | head -n1 || which ruby
      SH
      path = out.lines.find { |l| l.strip.start_with?('/') }&.strip
      raise Error.new("no ruby found on remote (mise not installed for #{config.service_user}?)") if path.to_s.empty?
      path
    end
  end
end
