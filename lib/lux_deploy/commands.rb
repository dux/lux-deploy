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

      with_deploy_lock(ctx, force: opts[:force]) { deploy!(ctx, opts) }
    end

    def deploy!(ctx, opts)
      wipe_stale_new_release(ctx)
      ctx.ports ||= allocate_ports(ctx)

      step 'rsync code'
      # Source is config `src:` (default ./). An app may build an artifact in
      # local_before and point src: at it. "!*" drops any file whose name
      # starts with "!" at any depth - the disable convention (e.g.
      # !job.service, !scratch.rb never ship).
      ctx.ssh.rsync(ctx.config.src, "#{ctx.app_dir}/new-release/",
                    excludes: %w[.git tmp log node_modules .DS_Store coverage !*] +
                              [RemoteState::SNAPSHOT_DIR])

      step 'symlink shared dirs into new-release'
      ctx.ssh.run(<<~SH, as: :service)
        cd #{Shellwords.escape(ctx.app_dir)}/new-release && \
        ln -sfn ../shared/tmp tmp && \
        ln -sfn ../shared/log log && \
        ln -sfn ../.env       .env
      SH

      # Materialize the pinned toolchain now that mise.toml is on the server,
      # BEFORE render_artifacts -> detect_ruby_path globs for an installed
      # ruby, so the install has to come first.
      ensure_toolchain_installed(ctx)
      render_artifacts(ctx)

      step 'write rendered .env / systemd.service / caddy.config'
      upload_artifacts(ctx)

      run_remote_before_hook(ctx)

      # Two mv calls, so there is a sub-second window with no release/ dir. A
      # unit that crash-restarts inside it fails once and is picked up by the
      # next Restart=always cycle.
      step 'release swap'
      ctx.ssh.run(<<~SH, as: :service)
        cd #{Shellwords.escape(ctx.app_dir)} && \
        rm -rf old-release && \
        ( [ -d release ] && mv release old-release || true ) && \
        mv new-release release
      SH

      ensure_caddy_log_dir(ctx)

      step 'install systemd + caddy symlinks'
      install_system_symlinks(ctx)

      # Everything past the swap shares one failure policy: `keep` fails loudly
      # and leaves the release live, `rollback` puts the previous one back.
      with_failure_policy(ctx, opts) do
        restart_and_verify(ctx)
        run_remote_after_hook(ctx)
      end

      step "write #{Manifest::FILENAME}"
      upload_manifest(ctx)

      run_local_after_hook(ctx)

      step "done. https://#{ctx.domain} (#{ctx.ports.map { |k, v| "#{k}=#{v}" }.join(' ')})"
    end

    # -------- lifecycle hook commands -------------------------------------

    def hook(opts, side, timing)
      ctx = Context.build(opts)
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
      ctx = Context.build(opts)
      step "destroy #{ctx.app} on #{ctx.host}"
      confirm_destroy!(ctx) unless opts[:yes]

      # Units come from the remote manifest, not the local config/deploy scan -
      # a *.service file deleted or "!"-disabled since the last deploy is still
      # installed on the box, and tearing down only what the checkout knows
      # about leaves it orphaned forever.
      units = RemoteState.services(ctx)
      step "stop + disable systemd units (#{units.map(&:unit).join(' ')})"
      teardown_units(ctx, units)

      step 'unlink caddy site'
      ctx.ssh.run(<<~SH, allow_fail: true)
        rm -f #{CADDY_SITES}/#{ctx.app}.caddy
        systemctl reload caddy || true
      SH

      step "rm -rf #{ctx.app_dir}"
      ctx.ssh.run("rm -rf #{Shellwords.escape(ctx.app_dir)}", as: :service, allow_fail: true)

      step 'done.'
    end

    # -------- rollback -----------------------------------------------------

    # Put the previous release back. `up` keeps exactly one (old-release/), so
    # rollback depth is one - but the swap is symmetric, so running it twice
    # returns you to where you started.
    #
    # `from_services:` overrides what we consider currently installed. `up`
    # passes it on the on_fail path, because there the manifest on the box is
    # still the *previous* deploy's - it is only written after remote_after.sh
    # succeeds - so a unit this deploy introduced would otherwise be left
    # running against rolled-back code.
    def rollback(opts, from_services: nil)
      ctx = Context.build(opts)
      step "rollback #{ctx.app} on #{ctx.host}"

      dir  = Shellwords.escape(ctx.app_dir)
      have = ctx.ssh.run("[ -d #{dir}/old-release ] && echo __YES__ || true",
                         as: :service, allow_fail: true)
      unless ctx.ssh.dry_run || have.include?('__YES__')
        raise Error.new("nothing to roll back to: #{ctx.app_dir}/old-release does not exist on #{ctx.host}")
      end

      snapshot = "#{ctx.app_dir}/old-release/#{RemoteState::SNAPSHOT_DIR}"
      from     = RemoteState.read_manifest(ctx)
      to       = RemoteState.read_manifest(ctx, dir: snapshot)

      step "from #{RemoteState.commit(from)}"
      step "to   #{RemoteState.commit(to)}"
      confirm_rollback!(ctx) unless opts[:yes] || ctx.ssh.dry_run

      # `release` may be absent - a deploy killed inside the two-mv swap window
      # leaves exactly that state, and it is the case rollback most needs to
      # repair, so the swap must not require it.
      step 'swap release <-> old-release'
      ctx.ssh.run(<<~SH, as: :service)
        set -e
        cd #{dir}
        rm -rf rollback-tmp
        if [ -d release ]; then mv release rollback-tmp; fi
        mv old-release release
        if [ -d rollback-tmp ]; then mv rollback-tmp old-release; fi
      SH

      step 'restore rendered artifacts from the release snapshot'
      restore_artifacts(ctx)

      # Units come from the restored release's own manifest, not the local
      # checkout - a service file added since that release must not be
      # restarted, and one dropped since then must not be forgotten.
      old_units = from_services || RemoteState.manifest_services(from)
      new_units = RemoteState.services(ctx, to)
      stale     = stale_units(old_units, new_units)

      step "stop units the restored release does not have (#{stale.map(&:unit).join(' ')})" unless stale.empty?
      teardown_units(ctx, stale)

      step 'install systemd + caddy symlinks'
      install_system_symlinks(ctx, new_units)

      # No failure policy here - if the restored release is also unhealthy,
      # rolling back again would just oscillate. Fail and say so.
      restart_and_verify(ctx, new_units)

      step "done. rolled back to #{RemoteState.commit(to)} - https://#{ctx.domain}"
    end

    # Copy <release>/.lux-deploy/* back over <app_dir>/. Tolerates a missing
    # snapshot (a release deployed before snapshots existed): the app_dir
    # artifacts are then left as they are and only the code was rolled back.
    def restore_artifacts(ctx)
      dir = Shellwords.escape(ctx.app_dir)
      ctx.ssh.run(<<~SH, as: :service)
        set -e
        snap=#{dir}/release/#{RemoteState::SNAPSHOT_DIR}
        if [ ! -d "$snap" ]; then
          echo "no #{RemoteState::SNAPSHOT_DIR}/ in the restored release - keeping current .env / units / caddy.config"
          exit 0
        fi
        for f in "$snap"/* "$snap"/.[!.]*; do
          [ -f "$f" ] || continue
          cp -f "$f" #{dir}/
          chmod 0644 #{dir}/"$(basename "$f")"
        done
        chmod 0600 #{dir}/.env 2>/dev/null || true
      SH
    end

    # Units that were installed but the restored release does not have. Left
    # alone they keep running against code that is no longer there.
    def stale_units(installed, restored)
      names = restored.map(&:unit)
      installed.reject { |s| names.include?(s.unit) }
    end

    def confirm_rollback!(ctx)
      $stderr.print "roll back #{ctx.app} on #{ctx.host}? type 'yes' to confirm: "
      typed = $stdin.gets.to_s.strip
      raise Error.new('aborted; pass --yes to skip prompt') unless typed == 'yes'
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
      Doctor.run(ssh, config, fix: opts.fetch(:fix, true), dry_run: opts[:dry_run] || false)
    end

    # -------- prepare:* ----------------------------------------------------

    # Bootstrap the host (install, sites dir, directive, enable). Host setup
    # only. Builds ssh directly from host + config (no app/domain resolution
    # needed).

    def prepare_caddy(opts)
      ssh = prepare_ssh(opts)
      step "prepare caddy on #{ssh.host}"
      Prepare.caddy(ssh)
      step "done. caddy installed, #{CADDY_SITES} wired, service running"
    end

    def prepare_mise(opts)
      ssh = prepare_ssh(opts)
      step "prepare mise on #{ssh.host}"
      Prepare.mise(ssh)
      step "done. mise installed for #{ssh.service_user}, activated in login shell"
    end

    def prepare_bun(opts)
      ssh = prepare_ssh(opts)
      step "prepare bun on #{ssh.host}"
      Prepare.bun(ssh)
      step "done. bun installed for #{ssh.service_user}"
    end

    # -------- caddy:log:* --------------------------------------------------

    # Host setup for access-log ingestion: bun + the bundled importer script +
    # one host-wide systemd service scanning every app's log dir. Idempotent.
    def caddy_log_prepare(opts)
      config = Config.load
      ssh    = prepare_ssh(opts)
      step "prepare caddy log importer on #{ssh.host}"
      Prepare.bun(ssh)
      Prepare.install_importer(ssh, IMPORTER_LOCAL, IMPORTER_REMOTE)
      Prepare.caddy_log_service(ssh, scan_root: config.remote_base,
                                     importer: IMPORTER_REMOTE, retain: IMPORTER_RETAIN)
      step "done. #{IMPORTER_UNIT} scanning #{config.remote_base}/*/log (retain #{IMPORTER_RETAIN}d)"
    end

    # Per-app inspection: host-wide importer unit status + this app's log dir
    # listing + SQLite stats (row count, ts span, checkpoint).
    def caddy_log_status(opts)
      ctx = Context.build(opts)
      dir = "#{ctx.app_dir}/log"
      bun = "#{ctx.service_home}/.bun/bin/bun"
      step "caddy log status for #{ctx.app}"
      ctx.ssh.stream("systemctl status #{IMPORTER_UNIT} --no-pager", allow_fail: true)
      ctx.ssh.stream("ls -lh #{Shellwords.escape(dir)}/ 2>/dev/null || true", as: :service, allow_fail: true)
      ctx.ssh.stream("#{bun} #{Shellwords.escape(IMPORTER_REMOTE)} stats --db #{Shellwords.escape("#{dir}/caddy.sqlite")}",
                     as: :service, allow_fail: true)
    end

    def prepare_ssh(opts)
      config = Config.load
      SSH.new(Context.read_host(opts), service_user: config.service_user,
                                       dry_run: opts[:dry_run] || false)
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

    # -------- env:* --------------------------------------------------------

    # Server-side env overlay. <app_dir>/.env is rendered from the repo
    # template on every deploy, so anything set on the box used to vanish on
    # the next `up`; .env.local is the file that survives. These commands are
    # sugar over editing it - `server:ssh` and $EDITOR does the same thing.
    ENV_LOCAL ||= '.env.local'

    def env_list(opts)
      ctx = Context.build(opts)
      env = Template.parse_env(read_remote_file(ctx, "#{ctx.app_dir}/.env"))
      raise Error.new("no #{ctx.app_dir}/.env on #{ctx.host} - deploy first") if env.empty?

      overlay = Template.parse_env_raw(read_remote_file(ctx, "#{ctx.app_dir}/#{ENV_LOCAL}")).keys
      step "env for #{ctx.app} on #{ctx.host} (secrets redacted; * = set in #{ENV_LOCAL})"
      width = env.keys.map { |k| k.to_s.length }.max
      env.each do |k, v|
        value = Manifest.sensitive?(k) || Manifest.sensitive_value?(v) ? '<redacted>' : v
        puts format("  %-<key>#{width}s  %<mark>s %<value>s",
                    key: k, mark: overlay.include?(k.to_s) ? '*' : ' ', value: value)
      end
    end

    # Unredacted single value - this one is for scripting, so it prints the
    # bare value on stdout and nothing else.
    def env_get(opts)
      key = Array(opts[:args]).first.to_s.strip
      raise Error.new('usage: lux-deploy env:get KEY') if key.empty?
      ctx = Context.build(opts)
      env = Template.parse_env(read_remote_file(ctx, "#{ctx.app_dir}/.env"))
      raise Error.new("#{key} is not set") unless env.key?(key.to_sym)
      puts env[key.to_sym]
    end

    def env_set(opts)
      pairs = Array(opts[:args]).map { |a| a.to_s.split('=', 2) }
      raise Error.new('usage: lux-deploy env:set KEY=VALUE [KEY2=VALUE2]') if pairs.empty?
      bad = pairs.reject { |k, v| v && k.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) }
      raise Error.new("not KEY=VALUE: #{bad.map(&:first).join(' ')}") unless bad.empty?

      ctx = Context.build(opts)
      step "set #{pairs.map(&:first).join(' ')} in #{ctx.app_dir}/#{ENV_LOCAL}"
      write_env_overlay(ctx, merge_env(read_remote_file(ctx, "#{ctx.app_dir}/#{ENV_LOCAL}"), pairs.to_h))
    end

    def env_edit(opts)
      ctx    = Context.build(opts)
      editor = ENV['EDITOR'] || ENV['VISUAL'] || 'vi'
      remote = "#{ctx.app_dir}/#{ENV_LOCAL}"
      step "edit #{remote} with #{editor}"
      return if ctx.ssh.dry_run

      require 'tempfile'
      Tempfile.create(['lux-deploy-env', '.env']) do |f|
        f.write(read_remote_file(ctx, remote))
        f.flush
        before = File.read(f.path)
        # Single-string form so an EDITOR carrying flags ("code --wait") works.
        system("#{editor} #{Shellwords.escape(f.path)}") or
          raise Error.new("#{editor} exited non-zero; nothing changed")
        after = File.read(f.path)
        next step('unchanged') if before == after
        write_env_overlay(ctx, after)
      end
    end

    # Write the overlay and fold it straight into the live <app_dir>/.env, so
    # the change takes effect on restart instead of waiting for a deploy.
    # The next `up` re-renders and re-applies the same overlay.
    def write_env_overlay(ctx, body)
      write_remote_file(ctx, "#{ctx.app_dir}/#{ENV_LOCAL}", body, mode: '0600')

      live = read_remote_file(ctx, "#{ctx.app_dir}/.env")
      if live.strip.empty?
        step 'no live .env yet - the overlay applies on the next deploy'
        return
      end
      write_remote_file(ctx, "#{ctx.app_dir}/.env", merge_env(live, read_env_overlay(ctx)), mode: '0600')

      # Caddy config did not change, so there is nothing to reload there.
      restart_and_verify(ctx, RemoteState.services(ctx), reload_proxy: false)
    end

    # -------- status / host:apps -------------------------------------------

    # What is actually live, read from the manifest the last deploy wrote plus
    # a look at systemd and the listening sockets.
    def status(opts)
      ctx = Context.build(opts)
      man = RemoteState.read_manifest(ctx)
      raise Error.new("no #{Manifest::FILENAME} in #{ctx.app_dir} on #{ctx.host} - deploy first") unless man

      step "status #{ctx.app} on #{ctx.host}"
      local = Manifest.capture('git rev-parse --short HEAD')
      live  = man.dig('git', 'commit_short')
      puts "  commit      #{RemoteState.commit(man)}#{live && local && live != local ? "  (local HEAD is #{local})" : ''}"
      puts "  branch      #{man.dig('git', 'branch')}"
      puts "  deployed    #{man['deployed_at']} by #{man.dig('deploy', 'triggered_by')}"
      puts "  url         #{man['url']}"

      units = RemoteState.services(ctx, man)
      active = ctx.ssh.run(units.map { |s| "echo \"#{s.unit} $(systemctl is-active #{s.unit} 2>/dev/null)\"" }.join("\n"),
                           allow_fail: true)
      puts '  services'
      active.lines.map(&:strip).reject(&:empty?).each { |l| puts "    #{l}" }

      ports = (man.dig('deploy', 'ports') || {})
      unless ports.empty?
        listening = scan_listening_ports(ctx)
        puts '  ports'
        ports.each { |k, v| puts "    #{k}=#{v} #{listening.include?(v.to_i) ? 'listening' : 'NOT listening'}" }
      end

      report_wiring(ctx, units)

      has_old = ctx.ssh.run("[ -d #{Shellwords.escape(ctx.app_dir)}/old-release ] && echo yes || echo no",
                            as: :service, allow_fail: true)
      puts "  rollback    #{has_old.include?('yes') ? 'available (lux-deploy rollback)' : 'unavailable'}"
    end

    # Symlinks are the whole install: /etc/caddy/sites and /etc/systemd/system
    # point back into <app_dir>. A dangling one is invisible until traffic
    # arrives, so `status` resolves each and re-checks the port contract end to
    # end - what caddy proxies to must be what .env says.
    def report_wiring(ctx, units)
      links = [[CADDY_SITES, "#{ctx.app}.caddy"]] +
              units.map { |s| [SYSTEMD_DIR, "#{s.unit}.service"] }

      out = ctx.ssh.run(<<~SH, allow_fail: true)
        for l in #{links.map { |dir, name| Shellwords.escape("#{dir}/#{name}") }.join(' ')}; do
          if [ -L "$l" ] && [ -e "$l" ]; then echo "ok       $l -> $(readlink "$l")"
          elif [ -L "$l" ];               then echo "BROKEN   $l -> $(readlink "$l")"
          else                                 echo "MISSING  $l"
          fi
        done
      SH
      puts '  wiring'
      out.lines.map(&:rstrip).reject(&:empty?).each { |l| puts "    #{l}" }

      upstream = read_remote_file(ctx, "#{ctx.app_dir}/caddy.config")[/reverse_proxy\s+\S*?:(\d+)/, 1]
      env_port = read_existing_ports(ctx)[:PORT]
      return unless upstream && env_port
      match = upstream.to_i == env_port
      puts "    #{match ? 'ok      ' : 'MISMATCH'} caddy proxies to :#{upstream}, .env PORT=#{env_port}"
    end

    # Every app on the host, straight from the manifests. One ssh round trip.
    def host_apps(opts)
      config = Config.load
      ssh    = prepare_ssh(opts)
      step "apps in #{config.remote_base} on #{ssh.host}"

      raw = ssh.run(<<~SH, allow_fail: true)
        for f in #{Shellwords.escape(config.remote_base)}/*/#{Manifest::FILENAME}; do
          [ -f "$f" ] || continue
          echo "__APP__ $f"
          cat "$f"
        done
      SH

      rows = raw.split('__APP__ ').drop(1).filter_map do |chunk|
        man = RemoteState.parse(chunk.split("\n", 2).last)
        next unless man
        [man['app'].to_s,
         man.dig('git', 'branch').to_s,
         RemoteState.commit(man),
         (man.dig('deploy', 'ports') || {}).values.join(','),
         man['deployed_at'].to_s]
      end

      return puts('  (none)') if rows.empty?
      head  = %w[APP BRANCH COMMIT PORTS DEPLOYED]
      width = head.each_index.map { |i| ([head[i]] + rows.map { |r| r[i] }).map(&:length).max }
      [head, *rows.sort_by(&:first)].each do |r|
        puts '  ' + r.each_with_index.map { |c, i| c.ljust(width[i]) }.join('  ').rstrip
      end
    end

    # -------- server:ssh --------------------------------------------------

    def server_ssh(opts)
      ctx = Context.build(opts)
      step "ssh #{ctx.app_dir}/release (#{ctx.config.service_user})"
      ctx.ssh.exec(
        "cd #{Shellwords.escape(ctx.app_dir)}/release && exec bash -li",
        as: :service
      )
    end

    # -------- server:log --------------------------------------------------

    def server_log(opts)
      ctx = Context.build(opts)
      unit = web_unit(ctx)
      step "journalctl -fu #{unit}"
      ctx.ssh.exec("journalctl -u #{unit} -n 200 -f")
    end

    # -------- log ---------------------------------------------------------

    # `lux-deploy log` lists the shared release/log dir; `--log <name>` dumps the
    # last `--lines` (200) lines of that file (the `.log` suffix is optional).
    def log(opts)
      ctx     = Context.build(opts)
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
      ctx = Context.build(opts)
      unit = web_unit(ctx)
      step "restart #{unit}"
      ctx.ssh.run("systemctl restart #{unit}")
    end

    # -------- server:status -----------------------------------------------

    def server_status(opts)
      ctx = Context.build(opts)
      unit = web_unit(ctx)
      step "status #{unit}"
      ctx.ssh.stream("systemctl status #{unit} --no-pager", allow_fail: true)
    end

    # -------- server:errors -----------------------------------------------

    def server_errors(opts)
      ctx  = Context.build(opts)
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

    # -------- health gate --------------------------------------------------

    # The port contract, checked. lux-deploy handed the app a PORT; this is
    # where the engine confirms the app took it, before caddy is pointed at
    # the new release and before remote_after.sh runs.
    #
    # Deliberately protocol-free: a listening socket is the whole contract, so
    # it works for any language with nothing installed on the box. An HTTP
    # probe is opt-in (`health_path:`), and config/deploy/health.sh replaces
    # the built-in check entirely.
    HEALTH_HOOK ||= 'config/deploy/health.sh'

    def run_health_gate(ctx, services = ctx.services)
      unless ctx.config.health?
        step 'health gate disabled (health: false)'
        return
      end
      return run_health_hook(ctx) if File.exist?(HEALTH_HOOK)

      await_ports(ctx, gate_ports(ctx), services)
      assert_units_active(ctx, services)
    end

    # `up` knows the ports it just allocated; rollback and env:set have to read
    # them back out of the live .env.
    def gate_ports(ctx)
      ports = ctx.ports || read_existing_ports(ctx)
      ports.reject { |_k, v| v.to_i.zero? }
    end

    def await_ports(ctx, ports, services)
      if ports.empty?
        step 'health gate: no ports to wait for'
        return
      end
      timeout = ctx.config.boot_timeout
      step "health gate: wait for #{ports.map { |k, v| "#{k}=#{v}" }.join(' ')} (#{timeout}s)"

      out = ctx.ssh.run(<<~SH, allow_fail: true)
        for p in #{ports.values.join(' ')}; do
          up=
          i=0
          while [ $i -lt #{timeout} ]; do
            if ss -tlnH | awk '{print $4}' | sed 's/.*://' | grep -qx "$p"; then up=1; break; fi
            i=$((i + 1))
            sleep 1
          done
          [ -n "$up" ] || { echo "__DOWN__ $p"; exit 1; }
        done
        #{http_probe_sh(ctx)}
        echo __UP__
      SH
      return if out.include?('__UP__') || ctx.ssh.dry_run

      dump_journal(ctx, services)
      raise Error.new("health gate failed: #{gate_failure(out)}.\n" \
                      "  The release is swapped in but is not serving. Fix and re-run `lux-deploy up`, " \
                      "or `lux-deploy rollback`.")
    end

    # Optional HTTP probe on the web port, appended to the same remote script
    # so it shares the one round trip. Empty unless `health_path:` is set.
    def http_probe_sh(ctx)
      path = ctx.config.health_path
      port = (ctx.ports || read_existing_ports(ctx))[:PORT]
      return '' unless path && port

      <<~SH.chomp
        if ! curl -fsS -m 5 -o /dev/null "http://127.0.0.1:#{port}#{path}"; then
          echo "__UNHEALTHY__ http://127.0.0.1:#{port}#{path}"
          exit 1
        fi
      SH
    end

    # A unit can bind its port and then die; systemd knows before we do.
    def assert_units_active(ctx, services)
      out = ctx.ssh.run(services.map { |s| "echo \"#{s.unit} $(systemctl is-active #{s.unit} 2>/dev/null)\"" }.join("\n"),
                        allow_fail: true)
      dead = out.lines.map(&:split).select { |_u, state| state && state != 'active' }
      return if dead.empty?

      dump_journal(ctx, services)
      raise Error.new("health gate failed: #{dead.map { |u, s| "#{u} is #{s}" }.join(', ')}")
    end

    def gate_failure(out)
      return "nothing listening on port #{$1}" if out =~ /__DOWN__ (\d+)/
      return "#{$1} did not answer" if out =~ /__UNHEALTHY__ (\S+)/
      'probe did not complete'
    end

    # The journal is the first thing anyone would look at next, so print it
    # rather than making them go find it.
    def dump_journal(ctx, services, lines: 40)
      services.each do |s|
        $stderr.puts "  --- journalctl -u #{s.unit} -n #{lines} ---"
        ctx.ssh.stream("journalctl -u #{s.unit} -n #{lines} --no-pager", allow_fail: true)
      end
    end

    # config/deploy/health.sh replaces the built-in probe outright - same shape
    # as the other hooks (server, in release/, .env sourced), so "wire it up
    # yourself" means editing a file you can already read.
    def run_health_hook(ctx)
      step "health gate: run #{HEALTH_HOOK} (server, in release, .env sourced)"
      ok = ctx.ssh.stream(<<~SH, as: :service, allow_fail: true)
        set -e
        cd #{Shellwords.escape(ctx.app_dir)}/release
        #{env_source_sh('.env')}
        export BOOT_TIMEOUT=#{ctx.config.boot_timeout}
        set -uo pipefail
        source #{Shellwords.escape(HEALTH_HOOK)}
      SH
      return if ok
      raise Error.new("#{HEALTH_HOOK} failed; the release is swapped in but is not serving.")
    end

    # -------- deploy lock --------------------------------------------------

    # Two deploys of the same app at once interleave the rsync and the swap and
    # produce a release that is neither. flock can't span separate ssh
    # invocations, so the lock is a file: created with noclobber (O_EXCL, so the
    # create is atomic) and removed on the way out.
    LOCK_FILE  ||= '.deploy.lock'
    LOCK_STALE ||= 60 # minutes; older than this and the holder is presumed dead

    def with_deploy_lock(ctx, force: false)
      acquire_deploy_lock(ctx, force: force)
      begin
        yield
      ensure
        release_deploy_lock(ctx)
      end
    end

    def acquire_deploy_lock(ctx, force: false)
      step "take deploy lock (#{ctx.app_dir}/#{LOCK_FILE})"
      path = "#{Shellwords.escape(ctx.app_dir)}/#{LOCK_FILE}"
      info = "pid=#{Process.pid} by=#{Manifest.triggered_by} at=#{Time.now.utc.iso8601}"

      # noclobber lives in a subshell: its "cannot overwrite existing file" is
      # emitted while setting up the redirection, before the `2>/dev/null` in
      # the same list takes effect, so it has to be silenced from outside.
      out = ctx.ssh.run(<<~SH, as: :service, allow_fail: true)
        if ( set -C; echo #{Shellwords.escape(info)} > #{path} ) 2>/dev/null; then
          echo __ACQUIRED__
          exit 0
        fi
        held=$(cat #{path} 2>/dev/null)
        if [ -n "#{force ? '1' : ''}" ] || [ -z "$(find #{path} -mmin -#{LOCK_STALE} 2>/dev/null)" ]; then
          echo "__BROKEN__ $held"
          echo #{Shellwords.escape(info)} > #{path}
          exit 0
        fi
        echo "__HELD__ $held"
      SH

      if out.include?('__HELD__')
        held = out[/__HELD__ (.*)/, 1].to_s.strip
        raise Error.new("deploy already running for #{ctx.app} on #{ctx.host} (#{held}).\n" \
                        "  Wait for it, or pass --force to break the lock " \
                        "(it expires on its own after #{LOCK_STALE} minutes).")
      end
      warn "  broke stale deploy lock (#{out[/__BROKEN__ (.*)/, 1].to_s.strip})" if out.include?('__BROKEN__')
    end

    def release_deploy_lock(ctx)
      step 'release deploy lock'
      ctx.ssh.run("rm -f #{Shellwords.escape(ctx.app_dir)}/#{LOCK_FILE}", as: :service, allow_fail: true)
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

    # Enable + restart every discovered service. daemon-reload first so changed
    # unit files are picked up. set -e aborts (and run raises) on the first
    # failure. Caddy is reloaded separately, after the health gate, so a
    # release that never boots does not get traffic pointed at it.
    def restart_services(ctx, services = ctx.services)
      lines = ['set -e', 'systemctl daemon-reload']
      services.each do |s|
        lines << "systemctl enable --now #{s.unit}"
        lines << "systemctl restart #{s.unit}"
      end
      ctx.ssh.run(lines.join("\n"))
    end

    def reload_caddy(ctx)
      ctx.ssh.run('systemctl reload caddy')
    end

    # Restart, prove it came up, then point caddy at it. Used by `up`,
    # `rollback` and `env:set` so all three get the same guarantee.
    def restart_and_verify(ctx, services = ctx.services, reload_proxy: true)
      step 'restart services'
      restart_services(ctx, services)
      run_health_gate(ctx, services)
      return unless reload_proxy
      step 'reload caddy'
      reload_caddy(ctx)
    end

    def ensure_remote_dirs(ctx)
      step 'ensure remote dirs'
      ctx.ssh.run(<<~SH, as: :service)
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/tmp
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/log
      SH
    end

    # Caddy (caddy user) writes the JSONL access log; the lux-caddylog importer
    # (service user) reads it and writes caddy.sqlite in the same dir. Pre-create
    # <app_dir>/log as service_user:caddy 2775 (setgid) so caddy writes via the
    # group and the service user owns it - paired with `mode 0644` on caddy's
    # file output. Runs as root for the cross-user chown. Only when the rendered
    # caddy.config actually emits a .jsonl, so non-logging apps are untouched.
    # Falls back to the service user's own group on hosts with no caddy.
    def ensure_caddy_log_dir(ctx)
      return unless ctx.rendered['caddy.config'].to_s.match?(/output file \S*\.jsonl/)
      step 'ensure caddy log dir (<app_dir>/log)'
      dir = "#{ctx.app_dir}/log"
      ctx.ssh.run(<<~SH)
        grp=caddy; getent group caddy >/dev/null 2>&1 || grp=#{ctx.config.service_user}
        install -d -o #{ctx.config.service_user} -g "$grp" -m 2775 #{Shellwords.escape(dir)}
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
        in_use = scan_listening_ports(ctx) | claimed_ports(ctx) | existing.values.to_set
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

    # Ports claimed by every app on the host, listening or not. `ss` alone only
    # sees bound sockets, so an app that is deployed but stopped (crashed,
    # mid-deploy, between destroy and up) would have its port handed to the
    # next app. The .env files stay the record - no ledger to keep in sync.
    def claimed_ports(ctx)
      # remote_base is escaped but the glob is not - it has to expand remotely.
      ctx.ssh.run("grep -hE '^PORT[A-Z0-9_]*=' #{Shellwords.escape(ctx.config.remote_base)}/*/.env 2>/dev/null || true",
                  as: :service, allow_fail: true)
        .lines.filter_map { |l| l.strip =~ /^PORT[A-Z0-9_]*=(\d+)/ ? $1.to_i : nil }.to_set
    end

    # Install whatever the app pins in mise.toml (ruby, node, ...) before the
    # render probes for ruby. Runs in new-release/ so mise reads the app's own
    # pin - no version parsing here. Gated on the file existing, so non-mise
    # apps (system ruby, asdf, Go/Python) are untouched. trust silences mise's
    # first-run y/n on a config path it hasn't seen; both are idempotent.
    def ensure_toolchain_installed(ctx)
      step 'mise install (pinned toolchain)'
      ctx.ssh.stream(<<~SH, as: :service)
        set -e
        cd #{Shellwords.escape(ctx.app_dir)}/new-release
        if [ -f mise.toml ]; then
          mise trust mise.toml >/dev/null 2>&1 || true
          mise install
        else
          echo "no mise.toml, skipping mise install"
        fi
      SH
    end

    # One-pass render. Every template (.env, caddy.conf, and each
    # *.service unit) is rendered with the same var set: git-derived + yaml +
    # engine-dynamic (PORT*/DIR, plus RUBY/RUBY_DIR when referenced).
    # The rendered .env never feeds back into the namespace - it is a
    # runtime-only file the app reads at boot, opaque to the engine.
    def render_artifacts(ctx)
      step 'render templates'

      # SERVICE_USER / SERVICE_HOME are engine-derived rather than yaml
      # placeholders (service_user is behavioral), but units need them or a
      # non-default service_user silently deploys a unit running as deployer.
      vars = ctx.base_vars.merge(ctx.ports).merge(
        DIR:          ctx.app_dir,
        LOG_DIR:      "#{ctx.app_dir}/log",
        LOG_NAME:     ctx.app,
        SERVICE_USER: ctx.config.service_user,
        SERVICE_HOME: ctx.service_home
      )
      # RUBY/RUBY_DIR (and the ssh ruby probe) only when a template asks for
      # them - a Go/Python unit running a built binary never triggers it.
      if ctx.ruby_used?
        vars = vars.merge(RUBY: ctx.ruby_path, RUBY_DIR: File.dirname(ctx.ruby_path))
      end

      # .env.local (server-only, set by `env:set`) layers over the rendered
      # template, then PORT* over that - ports are engine-owned, so a pinned
      # PORT in the overlay would just desync caddy from the unit.
      # Persisting the ports into .env is also what makes allocate_ports
      # reuse them next deploy instead of drifting.
      env_body = Template.render(ctx.read_template(ctx.env_template_name), vars)
      env_body = merge_env(env_body, read_env_overlay(ctx))
      env_body = merge_env(env_body, ctx.ports)

      rendered = {
        '.env'         => env_body,
        'caddy.config' => Template.render(ctx.read_template('caddy.conf'), vars)
      }
      ctx.services.each do |s|
        rendered[s.artifact] = Template.render(ctx.read_template(s.template), vars)
      end
      ctx.rendered = rendered
    end

    # Merge KEY=value pairs into a .env body: replace an existing `KEY=` line
    # or append one. The `=` anchor keeps PORT= from clobbering PORT_FOO=.
    def merge_env(env_body, pairs)
      pairs.each do |key, val|
        re = /^#{Regexp.escape(key.to_s)}=.*$/
        if env_body.match?(re)
          env_body = env_body.sub(re, "#{key}=#{val}")
        else
          env_body += "\n" unless env_body.empty? || env_body.end_with?("\n")
          env_body += "#{key}=#{val}\n"
        end
      end
      env_body
    end

    # Operator-set env that lives only on the server, merged over the rendered
    # .env on every deploy - so `env:set` survives a redeploy. The repo
    # template keeps the shape of the env; the box holds the values.
    def read_env_overlay(ctx)
      pairs   = Template.parse_env_raw(read_remote_file(ctx, "#{ctx.app_dir}/#{ENV_LOCAL}"))
      managed = pairs.keys.grep(/\APORT[A-Z0-9_]*\z/)
      unless managed.empty?
        warn "  #{ENV_LOCAL}: ignoring #{managed.join(' ')} - PORT* are engine-allocated"
        managed.each { |k| pairs.delete(k) }
      end
      pairs
    end

    def read_remote_file(ctx, path)
      ctx.ssh.run("cat #{Shellwords.escape(path)} 2>/dev/null || true", as: :service, allow_fail: true)
    end

    # Upload rendered files atomically (write to .new, mv).
    # .env is 0600 (secrets); other artifacts are 0644 so caddy/systemd
    # (running as their own users) can read the symlinks into ctx.app_dir.
    #
    # Each artifact is also copied into new-release/.lux-deploy/ so it travels
    # with the code through the swap. Ports are stable across deploys, but
    # ExecStart and the caddy config are not - rolling code back without its
    # unit file gives a mismatched release.
    def upload_artifacts(ctx)
      snapshot = "#{ctx.app_dir}/new-release/#{RemoteState::SNAPSHOT_DIR}"
      ctx.rendered.each do |name, body|
        write_remote_file(ctx, "#{ctx.app_dir}/#{name}", body, mode: artifact_mode(name))
        write_remote_file(ctx, "#{snapshot}/#{name}", body, mode: artifact_mode(name))
      end
    end

    def artifact_mode(name) = name == '.env' ? '0600' : '0644'

    # Atomic remote write as the service user: base64 in, .new, mv, chmod.
    def write_remote_file(ctx, remote_path, body, mode: '0644')
      b64 = [body].pack('m0')
      ctx.ssh.run(<<~SH, as: :service)
        install -d #{Shellwords.escape(File.dirname(remote_path))}
        echo #{Shellwords.escape(b64)} | base64 -d > #{Shellwords.escape(remote_path)}.new
        mv #{Shellwords.escape(remote_path)}.new #{Shellwords.escape(remote_path)}
        chmod #{mode} #{Shellwords.escape(remote_path)}
      SH
    end

    # Strict mode is enforced by the engine, not by each hook script, so the
    # templates don't have to repeat `set -euo pipefail`. Sourcing (not `bash
    # <file>`) is what makes the flags apply inside the hook - a child `bash
    # <file>` would not inherit them.
    def run_local_hook(path, ctx)
      system(local_hook_env(ctx), 'bash', '-c', "set -euo pipefail\nsource #{Shellwords.escape(path)}")
    end

    # Local hooks get the deploy context in their environment so a notification
    # or cleanup script doesn't have to re-parse config/deploy/.yaml.
    def local_hook_env(ctx)
      {
        'LUX_DEPLOY_APP'    => ctx.app,
        'LUX_DEPLOY_DOMAIN' => ctx.domain,
        'LUX_DEPLOY_HOST'   => ctx.host,
        'LUX_DEPLOY_BRANCH' => ctx.branch.to_s,
        'LUX_DEPLOY_DIR'    => ctx.app_dir,
        'LUX_DEPLOY_PORT'   => ctx.port.to_s
      }
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
      run_local_hook(LOCAL_BEFORE_HOOK, ctx) or
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
        [ -f mise.toml ] && mise trust mise.toml >/dev/null 2>&1 || true
        #{env_source_sh('.env')}
        set -uo pipefail
        source #{Shellwords.escape(REMOTE_BEFORE_HOOK)}
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
        [ -f mise.toml ] && mise trust mise.toml >/dev/null 2>&1 || true
        #{env_source_sh('.env')}
        set -uo pipefail
        source #{Shellwords.escape(REMOTE_AFTER_HOOK)}
      SH
      return if ok
      raise Error.new(
        "#{REMOTE_AFTER_HOOK} failed.\n" \
        "  Active release remains live at #{ctx.app_dir}/release on #{ctx.host}; no automatic rollback was attempted."
      )
    end

    # Post-swap failures - the health gate or remote_after.sh - share one
    # policy. `keep` (default) fails loudly and leaves the new release live;
    # `rollback` puts the previous one back. Opt-in, because silent
    # auto-rollback is exactly the kind of magic this gem avoids.
    def with_failure_policy(ctx, opts)
      yield
    rescue Error => e
      raise unless ctx.config.rollback_on_fail?
      warn e.to_s
      step 'on_fail: rollback - restoring the previous release'
      rollback(opts.merge(yes: true), from_services: ctx.services)
      raise Error.new('deploy failed after the swap; rolled back to the previous release')
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
      return if run_local_hook(LOCAL_AFTER_HOOK, ctx)
      msg = "#{LOCAL_AFTER_HOOK} failed"
      strict ? raise(Error.new(msg)) : warn("#{msg} but deploy is already live; continuing")
    end

    # Build + upload the post-deploy snapshot to <app_dir>/lux-deploy.yaml.
    # 0644 so any user on the box can read it (it never contains secrets).
    # A copy lands in release/.lux-deploy/ too, so `rollback` can report which
    # commit it is restoring.
    def upload_manifest(ctx)
      body = Manifest.render(ctx)
      write_remote_file(ctx, "#{ctx.app_dir}/#{Manifest::FILENAME}", body)
      write_remote_file(ctx, "#{ctx.app_dir}/release/#{RemoteState::SNAPSHOT_DIR}/#{Manifest::FILENAME}", body)
    end

    def install_system_symlinks(ctx, services = ctx.services)
      lines = ["install -d #{CADDY_SITES} #{SYSTEMD_DIR}"]
      services.each do |s|
        lines << "ln -sfn #{Shellwords.escape(ctx.app_dir)}/#{s.artifact} #{SYSTEMD_DIR}/#{s.unit}.service"
      end
      lines << "ln -sfn #{Shellwords.escape(ctx.app_dir)}/caddy.config #{CADDY_SITES}/#{ctx.app}.caddy"
      ctx.ssh.run(lines.join("\n"))
    end

    # Stop, disable and unlink units. Used by destroy (everything) and by
    # rollback (only units the restored release no longer has).
    def teardown_units(ctx, services)
      return if services.empty?
      lines = services.flat_map do |s|
        ["systemctl disable --now #{s.unit} 2>/dev/null || true",
         "rm -f #{SYSTEMD_DIR}/#{s.unit}.service"]
      end
      lines << 'systemctl daemon-reload'
      ctx.ssh.run(lines.join("\n"), allow_fail: true)
    end
  end
end
