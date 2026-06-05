module LuxDeploy
  module Commands
    module_function

    # -------- up -----------------------------------------------------------

    def up(opts)
      ctx = Context.build(opts)
      step "deploy #{ctx.app} (branch #{ctx.branch}) -> #{ctx.host}"

      check_renamed_hooks!
      run_local_before_hook(ctx)

      ensure_remote_dirs(ctx)
      wipe_stale_new_release(ctx)
      ctx.ports ||= allocate_ports(ctx)
      render_artifacts(ctx)

      step 'rsync code'
      # Source is config `src:` (default ./). An app may build an artifact in
      # local_before and point src: at it. "!*" drops any file whose name
      # starts with "!" at any depth - the disable convention (e.g.
      # !job.service, !scratch.rb never ship).
      ctx.ssh.rsync(ctx.config.src, "#{ctx.app_dir}/new-release/",
                    excludes: %w[.git tmp log node_modules .DS_Store coverage !*])

      step 'symlink shared dirs into new-release'
      ctx.ssh.run(<<~SH, as: :service)
        cd #{Shellwords.escape(ctx.app_dir)}/new-release && \
        ln -sfn ../shared/tmp tmp && \
        ln -sfn ../shared/log log && \
        ln -sfn ../.env       .env
      SH

      step 'write rendered .env / systemd.service / caddy.config'
      upload_artifacts(ctx)

      run_remote_before_hook(ctx)

      step 'atomic release swap'
      ctx.ssh.run(<<~SH, as: :service)
        cd #{Shellwords.escape(ctx.app_dir)} && \
        rm -rf old-release && \
        ( [ -d release ] && mv release old-release || true ) && \
        mv new-release release
      SH

      step 'install systemd + caddy symlinks'
      install_system_symlinks(ctx)

      step 'reload services'
      reload_services(ctx)

      run_remote_after_hook(ctx)

      step "write #{Manifest::FILENAME}"
      upload_manifest(ctx)

      run_local_after_hook(ctx)

      step "done. https://#{ctx.domain} (#{ctx.ports.map { |k, v| "#{k}=#{v}" }.join(' ')})"
    end

    # -------- lifecycle hook commands -------------------------------------

    def hook(opts, side, timing)
      ctx = Context.build(opts, render: false)
      check_renamed_hooks!

      case [side.to_sym, timing.to_sym]
      when [:local, :before]  then run_local_before_hook(ctx)
      when [:remote, :before] then run_remote_before_hook(ctx)
      when [:remote, :after]  then run_remote_after_hook(ctx)
      when [:local, :after]   then run_local_after_hook(ctx, strict: true)
      else raise Error.new("unknown lifecycle hook: #{side}:#{timing}")
      end
    end

    # -------- destroy ------------------------------------------------------

    def destroy(opts)
      ctx = Context.build(opts, render: false)
      step "destroy #{ctx.app} on #{ctx.host}"
      confirm_destroy!(ctx) unless opts[:yes]

      step 'stop + disable systemd units'
      lines = ctx.services.flat_map do |s|
        ["systemctl disable --now #{s.unit} 2>/dev/null || true",
         "rm -f #{SYSTEMD_DIR}/#{s.unit}.service"]
      end
      lines << 'systemctl daemon-reload'
      ctx.ssh.run(lines.join("\n"), allow_fail: true)

      step 'unlink caddy site'
      ctx.ssh.run(<<~SH, allow_fail: true)
        rm -f #{CADDY_SITES}/#{ctx.app}.caddy
        systemctl reload caddy || true
      SH

      step "rm -rf #{ctx.app_dir}"
      ctx.ssh.run("rm -rf #{Shellwords.escape(ctx.app_dir)}", as: :service, allow_fail: true)

      step 'done.'
    end

    # -------- redeploy ----------------------------------------------------

    def redeploy(opts)
      destroy(opts)
      up(opts)
    end

    # -------- doctor ------------------------------------------------------

    def doctor(opts)
      host = Context.read_host(opts)
      config = Config.load
      ssh = SSH.new(host, service_user: config.service_user, dry_run: false)
      Doctor.run(ssh, config, fix: opts.fetch(:fix, true))
    end

    # -------- app:init ----------------------------------------------------

    # Copy every shipped template into ./config/deploy/. Existing files are
    # left untouched so re-running this is safe. The files are raw - users
    # edit them in place and the deploy step renders {{VAR}} placeholders.
    #
    # `templates_dir:` (passed via Hammer.register, or CLI --from) overrides
    # the gem's bundled generic templates; the lux-fw plugin uses this to
    # ship lux-flavored defaults without needing an adapter class.
    def init(opts)
      dest_dir    = './config/deploy'
      shipped_dir = opts[:templates_dir]&.to_s || LuxDeploy::ROOT.join('templates').to_s
      raise Error.new("templates dir not found: #{shipped_dir}") unless Dir.exist?(shipped_dir)

      FileUtils.mkdir_p(dest_dir)
      step "init #{dest_dir}/ from #{shipped_dir}"

      Dir.children(shipped_dir).sort.each do |name|
        src = File.join(shipped_dir, name)
        dst = File.join(dest_dir, name)
        next unless File.file?(src)

        if File.exist?(dst)
          $stderr.puts "  skip   #{name} (exists)"
        else
          FileUtils.cp(src, dst)
          $stderr.puts "  write  #{name}"
        end
      end

      $stderr.puts "done. edit #{dest_dir}/.env (SECRET, DOMAIN) and #{dest_dir}/.yaml, then run 'lux-deploy doctor' and 'lux-deploy up'"
    end

    # -------- server:ssh --------------------------------------------------

    def server_ssh(opts)
      ctx = Context.build(opts, render: false)
      step "ssh #{ctx.app_dir}/release (#{ctx.config.service_user})"
      ctx.ssh.exec(
        "cd #{Shellwords.escape(ctx.app_dir)}/release && exec bash -li",
        as: :service
      )
    end

    # -------- server:log --------------------------------------------------

    def server_log(opts)
      ctx = Context.build(opts, render: false)
      unit = web_unit(ctx)
      step "journalctl -fu #{unit}"
      ctx.ssh.exec("journalctl -u #{unit} -n 200 -f")
    end

    # -------- log ---------------------------------------------------------

    # `lux-deploy log` lists the shared release/log dir; `--log <name>` dumps the
    # last `--lines` (200) lines of that file (the `.log` suffix is optional).
    def log(opts)
      ctx     = Context.build(opts, render: false)
      log_dir = "#{ctx.app_dir}/release/log"

      if (name = opts[:log])
        name  = "#{name}.log" unless name.to_s.end_with?('.log')
        lines = (opts[:lines] || 200).to_i
        path  = "#{log_dir}/#{name}"
        step "tail -n #{lines} #{path}"
        ctx.ssh.stream("tail -n #{lines} #{Shellwords.escape(path)}", as: :service, allow_fail: true)
      else
        step "logs in #{log_dir}"
        ctx.ssh.stream("ls -lh #{Shellwords.escape(log_dir)}/", as: :service, allow_fail: true)
      end
    end

    # -------- server:restart ----------------------------------------------

    def server_restart(opts)
      ctx = Context.build(opts, render: false)
      unit = web_unit(ctx)
      step "restart #{unit}"
      ctx.ssh.run("systemctl restart #{unit}")
    end

    # -------- server:status -----------------------------------------------

    def server_status(opts)
      ctx = Context.build(opts, render: false)
      unit = web_unit(ctx)
      step "status #{unit}"
      ctx.ssh.stream("systemctl status #{unit} --no-pager", allow_fail: true)
    end

    # -------- server:errors -----------------------------------------------

    def server_errors(opts)
      ctx  = Context.build(opts, render: false)
      path = "#{ctx.app_dir}/release/log/error.log"
      step "tail -f #{path}"
      ctx.ssh.exec("tail -f #{Shellwords.escape(path)}", as: :service)
    end

    # -------- helpers ------------------------------------------------------

    def step(msg)
      $stderr.puts "==> #{msg}"
    end

    def confirm_destroy!(ctx)
      $stderr.print "type '#{ctx.domain}' to confirm destroy: "
      typed = $stdin.gets.to_s.strip
      raise Error.new('aborted; pass --yes to skip prompt') unless typed == ctx.domain
    end

    # Load a remote .env file into the current shell, exporting each
    # KEY=VALUE line. Safer than `. file` because each line is passed as
    # a single quoted argument to `export` - bash word-splitting and
    # glob expansion never touch the value. Strips surrounding "..." or
    # '...' from the value so `DOMAIN="a, *.b"` and `DOMAIN=a, *.b`
    # both yield DOMAIN=`a, *.b` (matching dotenv conventions).
    def env_source_sh(path)
      body = <<~'SH'.chomp
        while IFS= read -r __l || [ -n "$__l" ]; do
          case "$__l" in
            ''|\#*) continue ;;
            *=*) ;;
            *) continue ;;
          esac
          __v="${__l#*=}"
          case "$__v" in
            \"*\") __v="${__v#\"}"; __v="${__v%\"}" ;;
            \'*\') __v="${__v#\'}"; __v="${__v%\'}" ;;
          esac
          export "${__l%%=*}=$__v"
        done <
      SH
      "#{body} #{Shellwords.escape(path)}"
    end

    # Remove any new-release/ left behind by a prior failed deploy.
    # Runs at the start of `up` so a fresh rsync doesn't merge with
    # stale gem builds / half-installed assets.
    def wipe_stale_new_release(ctx)
      step 'wipe stale new-release (if any from prior failed deploy)'
      ctx.ssh.run("rm -rf #{Shellwords.escape(ctx.app_dir)}/new-release", as: :service, allow_fail: true)
    end

    # Web unit name (bare, no .service suffix since systemctl accepts both).
    # Used by server:restart/log/status which target the web service.
    def web_unit(ctx) = "#{ctx.config.service_prefix}-#{ctx.app}"

    # Enable + restart every discovered service, then reload caddy once.
    # daemon-reload first so changed unit files are picked up. set -e aborts
    # (and run raises) on the first failure.
    def reload_services(ctx)
      lines = ['set -e', 'systemctl daemon-reload']
      ctx.services.each do |s|
        lines << "systemctl enable --now #{s.unit}"
        lines << "systemctl restart #{s.unit}"
      end
      lines << 'systemctl reload caddy'
      ctx.ssh.run(lines.join("\n"))
    end

    def ensure_remote_dirs(ctx)
      step 'ensure remote dirs'
      ctx.ssh.run(<<~SH, as: :service)
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/tmp
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/log
      SH
    end

    # Resolve every managed PORT* token to a concrete port. Tokens come from
    # needed_port_keys (PORT* keys in .env + {{PORT*}} placeholders in any
    # template). Each is reused from the remote .env when present, else a free
    # port is allocated from PORT_RANGE. The ss scan only runs when at least
    # one new port must be allocated - re-deploys that reuse everything never
    # probe the host. Returns an ordered {PORT: 3010, PORT_FOO: 3020} hash.
    def allocate_ports(ctx)
      step 'allocate ports'
      needed   = needed_port_keys(ctx)
      existing = read_existing_ports(ctx)
      reused   = needed.select { |k| existing[k] }

      ports = {}
      reused.each { |k| ports[k] = existing[k] }

      to_assign = needed - reused
      unless to_assign.empty?
        in_use = scan_listening_ports(ctx) | existing.values.to_set
        to_assign.each do |k|
          free = PORT_RANGE.find { |p| !in_use.include?(p) }
          raise Error.new("no free port in 3010..3990 (step 10) for #{k}") unless free
          ports[k] = free
          in_use << free
        end
      end

      ordered = needed.each_with_object({}) { |k, h| h[k] = ports[k] }
      ordered.each do |k, v|
        $stderr.puts "    #{reused.include?(k) ? 'reusing' : 'allocated'} #{k}=#{v}"
      end
      ordered
    end

    # PORT* tokens this deploy manages: union of PORT-prefixed keys declared in
    # the .env template(s) and {{PORT*}} placeholders referenced by caddy /
    # systemd units. A web app with no explicit PORT still gets one because
    # caddy.conf references {{PORT}}.
    def needed_port_keys(ctx)
      keys = []
      [ctx.env_template_name, '.env'].uniq.each do |n|
        src = ctx.template_source(n) or next
        keys.concat(src.scan(/^(PORT[A-Z0-9_]*)\s*=/).flatten)
      end
      (['caddy.conf'] + ctx.services.map(&:template)).uniq.each do |n|
        src = ctx.template_source(n) or next
        keys.concat(src.scan(/\{\{(PORT[A-Z0-9_]*)\}\}/).flatten)
      end
      keys.uniq.map(&:to_sym)
    end

    # PORT* => Integer parsed from the remote .env (re-deploys reuse these).
    def read_existing_ports(ctx)
      out = ctx.ssh.run(
        "[ -f #{Shellwords.escape(ctx.app_dir)}/.env ] && " \
        "grep -E '^PORT[A-Z0-9_]*=' #{Shellwords.escape(ctx.app_dir)}/.env || true",
        as: :service, allow_fail: true
      )
      out.lines.each_with_object({}) do |l, h|
        h[$1.to_sym] = $2.to_i if l.strip =~ /^(PORT[A-Z0-9_]*)=(\d+)/
      end
    end

    def scan_listening_ports(ctx)
      ctx.ssh.run("ss -tlnH | awk '{print $4}' | sed 's/.*://'", allow_fail: true)
        .lines.map { |l| l.strip.to_i }.to_set
    end

    # One-pass render. Every template (.env, caddy.conf, and each
    # *.service unit) is rendered with the same var set: git-derived + yaml +
    # engine-dynamic (PORT*/DIR, plus RUBY/RUBY_DIR when referenced).
    # The rendered .env never feeds back into the namespace - it is a
    # runtime-only file the app reads at boot, opaque to the engine.
    def render_artifacts(ctx)
      step 'render templates'

      vars = ctx.base_vars.merge(ctx.ports).merge(DIR: ctx.app_dir)
      # RUBY/RUBY_DIR (and the ssh ruby probe) only when a template asks for
      # them - a Go/Python unit running a built binary never triggers it.
      if ctx.ruby_used?
        vars = vars.merge(RUBY: ctx.ruby_path, RUBY_DIR: File.dirname(ctx.ruby_path))
      end

      # Persist every allocated PORT* into .env so allocate_ports reuses the
      # same ports on the next deploy. Without this they only land in
      # systemd/caddy, the reuse path never fires, and ports drift.
      env_body = persist_ports(Template.render(ctx.read_template(ctx.env_template_name), vars), ctx.ports)

      rendered = {
        '.env'         => env_body,
        'caddy.config' => Template.render(ctx.read_template('caddy.conf'), vars)
      }
      ctx.services.each do |s|
        rendered[s.artifact] = Template.render(ctx.read_template(s.template), vars)
      end
      ctx.rendered = rendered
    end

    # Ensure every managed PORT* key appears with its value in the rendered
    # .env body: replace an existing `KEY=` line or append one. The `=` anchor
    # keeps PORT= from clobbering PORT_FOO=.
    def persist_ports(env_body, ports)
      ports.each do |key, val|
        if env_body =~ /^#{key}=.*$/
          env_body = env_body.sub(/^#{key}=.*$/, "#{key}=#{val}")
        else
          env_body += "\n" unless env_body.empty? || env_body.end_with?("\n")
          env_body += "#{key}=#{val}\n"
        end
      end
      env_body
    end

    # Upload rendered files atomically (write to .new, mv).
    # .env is 0600 (secrets); other artifacts are 0644 so caddy/systemd
    # (running as their own users) can read the symlinks into ctx.app_dir.
    def upload_artifacts(ctx)
      ctx.rendered.each do |name, body|
        remote_path = "#{ctx.app_dir}/#{name}"
        b64 = [body].pack('m0')
        mode = name == '.env' ? '0600' : '0644'
        ctx.ssh.run(<<~SH, as: :service)
          install -d #{Shellwords.escape(File.dirname(remote_path))}
          echo #{Shellwords.escape(b64)} | base64 -d > #{Shellwords.escape(remote_path)}.new
          mv #{Shellwords.escape(remote_path)}.new #{Shellwords.escape(remote_path)}
          chmod #{mode} #{Shellwords.escape(remote_path)}
        SH
      end
    end

    LOCAL_BEFORE_HOOK  ||= 'config/deploy/local_before.sh'
    REMOTE_BEFORE_HOOK ||= 'config/deploy/remote_before.sh'
    REMOTE_AFTER_HOOK  ||= 'config/deploy/remote_after.sh'
    LOCAL_AFTER_HOOK   ||= 'config/deploy/local_after.sh'

    # Hooks were renamed to a symmetric local_/remote_ scheme. Old names no
    # longer fire - abort with a rename hint rather than silently skipping a
    # hook the user believes still runs.
    RENAMED_HOOKS ||= {
      'config/deploy/before_local.sh'  => LOCAL_BEFORE_HOOK,
      'config/deploy/before_server.sh' => REMOTE_BEFORE_HOOK,
      'config/deploy/after_server.sh'  => REMOTE_AFTER_HOOK
    }.freeze

    def check_renamed_hooks!
      stale = RENAMED_HOOKS.select { |old, _| File.exist?(old) }
      return if stale.empty?
      body = stale.map { |old, new| "  mv #{old} #{new}" }.join("\n")
      raise Error.new("lifecycle hooks were renamed; rename these files:\n#{body}")
    end

    # Pre-flight gate. Runs locally in the project root before any remote
    # work. Optional - announced as "(not defined, skipping)" when the
    # file is absent so a missing hook is visible in the output, not
    # silent. Non-zero exit aborts the deploy.
    def run_local_before_hook(ctx)
      unless File.exist?(LOCAL_BEFORE_HOOK)
        step "run #{LOCAL_BEFORE_HOOK} (not defined, skipping)"
        return
      end
      step "run #{LOCAL_BEFORE_HOOK} (local)"
      if ctx.ssh.dry_run
        $stderr.puts "  [dry] bash #{LOCAL_BEFORE_HOOK}"
        return
      end
      system('bash', LOCAL_BEFORE_HOOK) or
        raise Error.new("#{LOCAL_BEFORE_HOOK} failed; deploy aborted (no remote state changed)")
    end

    # Install/migrate hook. Runs on the server inside new-release/ as the
    # service user, AFTER rsync + symlinks + .env upload, BEFORE the swap.
    # The rendered .env is sourced into the shell before the script runs
    # so DB_URL / SECRET / etc. are exported. This is where the user does
    # `bundle install`, `npm ci`, `go build`, db migrations, asset compile,
    # etc. - the engine itself is language-agnostic past this point.
    #
    # Optional - announced as "(not defined, skipping)" when absent so the
    # absence is visible. Non-zero exit aborts: the new-release/ dir is
    # kept for inspection, release/ is untouched.
    def run_remote_before_hook(ctx)
      unless File.exist?(REMOTE_BEFORE_HOOK)
        step "run #{REMOTE_BEFORE_HOOK} (not defined, skipping)"
        return
      end
      step "run #{REMOTE_BEFORE_HOOK} (server, in new-release, .env sourced)"
      ok = ctx.ssh.stream(<<~SH, as: :service, allow_fail: true)
        set -e
        cd #{Shellwords.escape(ctx.app_dir)}/new-release
        #{env_source_sh('.env')}
        bash #{Shellwords.escape(REMOTE_BEFORE_HOOK)}
      SH
      return if ok
      raise Error.new(
        "#{REMOTE_BEFORE_HOOK} failed; deploy aborted.\n" \
        "  release/ untouched. new-release/ kept at #{ctx.app_dir}/new-release on #{ctx.host}.\n" \
        "  Inspect: lux-deploy server:ssh   Retry hook: lux-deploy on:remote:before   Full redeploy: lux-deploy up"
      )
    end

    # Post-deploy server hook. Runs on the server inside release/ after the
    # swap and service reload, with the rendered .env sourced into the shell
    # (same shape as the remote-before hook so both sides see the same
    # exported vars). Optional - announced as "(not defined, skipping)"
    # when absent so the absence is visible. Non-zero exit fails the command
    # but does NOT roll back (deploy is already live).
    def run_remote_after_hook(ctx)
      unless File.exist?(REMOTE_AFTER_HOOK)
        step "run #{REMOTE_AFTER_HOOK} (not defined, skipping)"
        return
      end
      step "run #{REMOTE_AFTER_HOOK} (server, in release, .env sourced)"
      ok = ctx.ssh.stream(<<~SH, as: :service, allow_fail: true)
        set -e
        cd #{Shellwords.escape(ctx.app_dir)}/release
        #{env_source_sh('.env')}
        bash #{Shellwords.escape(REMOTE_AFTER_HOOK)}
      SH
      return if ok
      raise Error.new(
        "#{REMOTE_AFTER_HOOK} failed.\n" \
        "  Active release remains live at #{ctx.app_dir}/release on #{ctx.host}; no automatic rollback was attempted."
      )
    end

    # Post-deploy local hook. Runs in the project root after the remote deploy
    # succeeded and the manifest is written - notifications, cleanup of local
    # build artifacts produced by local_before. Optional - announced as "(not
    # defined, skipping)" when absent. Non-zero exit warns (deploy is live).
    def run_local_after_hook(ctx, strict: false)
      unless File.exist?(LOCAL_AFTER_HOOK)
        step "run #{LOCAL_AFTER_HOOK} (not defined, skipping)"
        return
      end
      step "run #{LOCAL_AFTER_HOOK} (local)"
      if ctx.ssh.dry_run
        $stderr.puts "  [dry] bash #{LOCAL_AFTER_HOOK}"
        return
      end
      return if system('bash', LOCAL_AFTER_HOOK)
      msg = "#{LOCAL_AFTER_HOOK} failed"
      strict ? raise(Error.new(msg)) : warn("#{msg} but deploy is already live; continuing")
    end

    # Build + upload the post-deploy snapshot to <app_dir>/lux-deploy.yaml.
    # Same atomic write pattern as upload_artifacts. 0644 so any user on
    # the box can read it (it never contains secrets).
    def upload_manifest(ctx)
      body = Manifest.render(ctx)
      remote = "#{ctx.app_dir}/#{Manifest::FILENAME}"
      b64 = [body].pack('m0')
      ctx.ssh.run(<<~SH, as: :service)
        echo #{Shellwords.escape(b64)} | base64 -d > #{Shellwords.escape(remote)}.new
        mv #{Shellwords.escape(remote)}.new #{Shellwords.escape(remote)}
        chmod 0644 #{Shellwords.escape(remote)}
      SH
    end

    def install_system_symlinks(ctx)
      lines = ["install -d #{CADDY_SITES} #{SYSTEMD_DIR}"]
      ctx.services.each do |s|
        lines << "ln -sfn #{Shellwords.escape(ctx.app_dir)}/#{s.artifact} #{SYSTEMD_DIR}/#{s.unit}.service"
      end
      lines << "ln -sfn #{Shellwords.escape(ctx.app_dir)}/caddy.config #{CADDY_SITES}/#{ctx.app}.caddy"
      ctx.ssh.run(lines.join("\n"))
    end
  end
end
