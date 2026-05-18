module LuxDeploy
  module Commands
    module_function

    # -------- up -----------------------------------------------------------

    def up(opts)
      ctx = Context.build(opts)
      step "deploy #{ctx.app} (branch #{ctx.branch}) -> #{ctx.host}"

      run_before_local_hook(ctx)

      ensure_remote_dirs(ctx)
      ctx.port ||= allocate_port(ctx)
      render_artifacts(ctx)

      step 'cache gems into vendor/cache'
      # Ship .gem files with the rsync so the server skips downloads for
      # platform-matching gems. Native gems (pg etc.) cached for darwin will
      # be re-fetched from rubygems on Debian and built locally - bundler
      # handles that fallback automatically, so a failure here is non-fatal.
      system('bundle', 'cache', '--no-install') or warn 'bundle cache failed, continuing without local cache'

      step 'rsync code'
      ctx.ssh.rsync('./', "#{ctx.app_dir}/new-release/",
                    excludes: %w[.git tmp log node_modules .DS_Store coverage])

      step 'symlink shared dirs into new-release'
      ctx.ssh.run(<<~SH, as: :service)
        cd #{Shellwords.escape(ctx.app_dir)}/new-release && \
        ln -sfn ../shared/tmp tmp && \
        ln -sfn ../shared/log log && \
        ln -sfn ../.env       .env
      SH

      step 'write rendered .env / systemd.service / caddy.config'
      upload_artifacts(ctx)

      step 'bundle install'
      # Bundler 4 dropped --deployment / --without flags. We also avoid
      # `deployment=true` because it implies `frozen=true`, which breaks apps
      # whose Gemfile resolves to different sources per environment (e.g.
      # local path -> .gems fallback). A fresh release dir has no prior
      # bundle config, so regenerating the lockfile is local to this release.
      ctx.ssh.stream(
        "cd #{Shellwords.escape(ctx.app_dir)}/new-release && " \
        '( [ -f mise.toml ] && mise trust mise.toml >/dev/null 2>&1 || true ) && ' \
        'bundle config set --local frozen false && ' \
        "bundle config set --local path vendor/bundle && " \
        "bundle config set --local without 'development test' && " \
        'bundle install --jobs 4 --retry 2',
        as: :service
      )

      smoke = ctx.config.smoke_command
      unless smoke
        ctx.ssh.run("rm -rf #{Shellwords.escape(ctx.app_dir)}/new-release", as: :service, allow_fail: true)
        raise Error.new(
          "config/deploy/.yaml: 'smoke_command:' is required.\n" \
          "  It runs in new-release/ after bundle install; non-zero exit rolls\n" \
          "  the deploy back. Use any command in any language - examples:\n" \
          "    smoke_command: bundle exec lux e 1\n" \
          "    smoke_command: bundle exec rails runner 'puts 1'\n" \
          "    smoke_command: bundle exec rspec spec/smoke\n" \
          "    smoke_command: ./bin/smoke"
        )
      end

      step "smoke test (#{smoke})"
      ok = ctx.ssh.stream(
        "cd #{Shellwords.escape(ctx.app_dir)}/new-release && #{smoke}",
        as: :service, allow_fail: true
      )
      unless ok
        warn 'smoke failed; rolling back (release/ untouched, removing new-release/)'
        ctx.ssh.run("rm -rf #{Shellwords.escape(ctx.app_dir)}/new-release", as: :service, allow_fail: true)
        raise Error.new("smoke test failed (#{ctx.app})")
      end

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
      web_unit = web_unit(ctx)
      ctx.ssh.run(<<~SH)
        systemctl daemon-reload && \
        systemctl enable --now #{web_unit} && \
        systemctl restart #{web_unit} && \
        systemctl reload caddy
      SH

      if ctx.job_template?
        step 'restart job service'
        job_unit = job_unit(ctx)
        ctx.ssh.run(<<~SH)
          systemctl enable --now #{job_unit} && \
          systemctl restart #{job_unit}
        SH
      end

      run_after_server_hook(ctx)

      step "write #{Manifest::FILENAME}"
      upload_manifest(ctx)

      step "done. https://#{ctx.domain} (port #{ctx.port})"
    end

    # -------- destroy ------------------------------------------------------

    def destroy(opts)
      ctx = Context.build(opts, render: false)
      step "destroy #{ctx.app} on #{ctx.host}"
      confirm_destroy!(ctx) unless opts[:yes]

      web_unit = web_unit(ctx)
      step 'stop + disable systemd units'
      lines = ["systemctl disable --now #{web_unit} 2>/dev/null || true"]
      lines << "rm -f #{SYSTEMD_DIR}/#{web_unit}.service"
      if ctx.config.job_service_prefix
        job_unit = job_unit(ctx)
        lines << "systemctl disable --now #{job_unit} 2>/dev/null || true"
        lines << "rm -f #{SYSTEMD_DIR}/#{job_unit}.service"
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

      $stderr.puts "done. edit #{dest_dir}/.env (SECRET, DB_URL, DOMAIN) and #{dest_dir}/.yaml, then run 'lux-deploy doctor' and 'lux-deploy up'"
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

    # -------- db:psql -----------------------------------------------------

    # Sources the remote .env so DB_URL never appears in the ssh command
    # line (which the logger would print).
    def db_psql(opts)
      ctx = Context.build(opts, render: false)
      step "psql #{ctx.app}"
      ctx.ssh.exec(<<~SH, as: :service)
        set -a && . #{Shellwords.escape(ctx.app_dir)}/.env && set +a && exec psql "$DB_URL"
      SH
    end

    # -------- db:pg:check -------------------------------------------------

    # Quick read-only probe of the remote DB. Connects via DB_URL from
    # server .env (sourced inside the ssh command so secrets never appear
    # on the ssh argv).
    def db_pg_check(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:check #{ctx.app} on #{ctx.host}"
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        echo "dbname: $DBNAME"
        psql "$DB_URL" -c "SELECT current_database() AS db, pg_size_pretty(pg_database_size(current_database())) AS size, (SELECT count(*) FROM information_schema.tables WHERE table_schema='public') AS public_tables, version() AS version"
      SH
    end

    # -------- db:pg:create -----------------------------------------------

    # CREATE DATABASE for the dbname embedded in remote .env DB_URL. We
    # connect to the maintenance db (postgres) using the same credentials.
    # Requires deployer's pg role to have CREATEDB (see doctor).
    def db_pg_create(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:create #{ctx.app} on #{ctx.host}"
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        echo "creating database $DBNAME"
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \\"$DBNAME\\""
      SH
    end

    # -------- db:pg:destroy ----------------------------------------------

    # DROP DATABASE for the dbname embedded in remote .env DB_URL. Same
    # type-the-domain confirmation as the app-level `destroy` so a typo
    # can't nuke prod.
    def db_pg_destroy(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:destroy #{ctx.app} on #{ctx.host}"
      confirm_pg_destroy!(ctx, 'DROP DATABASE') unless opts[:yes]
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        echo "dropping database $DBNAME"
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \\"$DBNAME\\""
      SH
    end

    # -------- db:pg:backup -----------------------------------------------

    # pg_dump on the server, scp the .sql.gz down, leave it compressed.
    # No restore (unlike pull). Timestamped so successive backups stack.
    def db_pg_backup(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:backup #{ctx.app} on #{ctx.host}"
      ts          = Time.now.strftime('%Y%m%d-%H%M%S')
      remote_dump = "/tmp/lux-deploy-#{ctx.app}-#{ts}.sql.gz"
      local_dump  = "./tmp/#{ctx.app}-#{ts}.sql.gz"

      FileUtils.mkdir_p('./tmp')
      step "pg_dump on #{ctx.host} -> #{remote_dump}"
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        pg_dump --no-privileges --no-owner "$DB_URL" | gzip > #{Shellwords.escape(remote_dump)}
      SH

      step "scp -> #{local_dump}"
      FileUtils.rm_f(local_dump)
      ctx.ssh.scp_from(remote_dump, local_dump)
      ctx.ssh.run("rm -f #{Shellwords.escape(remote_dump)}", as: :service, allow_fail: true)

      step "done. #{local_dump}"
    end

    # -------- db:pg:pull -------------------------------------------------

    # Dumps remote DB (via DB_URL from server .env) and restores into the
    # local DB pointed to by local $DB_URL. Drops + recreates local DB.
    def db_pg_pull(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:pull #{ctx.app} -> local"

      local_db_url = ENV['DB_URL'].to_s
      raise Error.new('local $DB_URL not set') if local_db_url.empty?
      local_db_name = local_db_url.split('/').last.to_s.split('?').first
      raise Error.new("can't parse db name from local DB_URL") if local_db_name.empty?

      FileUtils.mkdir_p('./tmp')
      remote_dump = "/tmp/lux-deploy-#{ctx.app}-dump.sql.gz"
      local_dump  = "./tmp/#{ctx.app}-dump.sql.gz"
      local_sql   = local_dump.sub(/\.gz$/, '')

      step "pg_dump on #{ctx.host} -> #{remote_dump}"
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        pg_dump --no-privileges --no-owner "$DB_URL" | gzip > #{Shellwords.escape(remote_dump)}
      SH

      step "scp -> #{local_dump}"
      FileUtils.rm_f(local_dump)
      ctx.ssh.scp_from(remote_dump, local_dump)
      ctx.ssh.run("rm -f #{Shellwords.escape(remote_dump)}", as: :service, allow_fail: true)

      step 'gunzip'
      FileUtils.rm_f(local_sql)
      system('gunzip', local_dump) or raise Error.new('gunzip failed')

      step "dropdb -f #{local_db_name} && createdb #{local_db_name}"
      system('dropdb', '-f', local_db_name) # may not exist; ignore
      system('createdb', local_db_name) or raise Error.new("createdb #{local_db_name} failed")

      step 'psql restore'
      system('bash', '-c', "psql #{Shellwords.escape(local_db_url)} < #{Shellwords.escape(local_sql)}") \
        or raise Error.new('psql restore failed')

      step "done. imported into #{local_db_name}"
    end

    # -------- db:pg:push -------------------------------------------------

    # Dumps local DB (via $DB_URL) and restores into the remote DB pointed
    # at by remote .env DB_URL. Drops + recreates the remote DB. Same
    # type-the-domain confirmation as destroy.
    def db_pg_push(opts)
      ctx = Context.build(opts, render: false)
      step "db:pg:push local -> #{ctx.app} on #{ctx.host}"
      confirm_pg_destroy!(ctx, 'OVERWRITE REMOTE DB') unless opts[:yes]

      local_db_url = ENV['DB_URL'].to_s
      raise Error.new('local $DB_URL not set') if local_db_url.empty?

      FileUtils.mkdir_p('./tmp')
      ts          = Time.now.strftime('%Y%m%d-%H%M%S')
      local_dump  = "./tmp/#{ctx.app}-push-#{ts}.sql.gz"
      remote_dump = "/tmp/lux-deploy-#{ctx.app}-push-#{ts}.sql.gz"

      step "pg_dump local -> #{local_dump}"
      FileUtils.rm_f(local_dump)
      ok = system('bash', '-c',
                  "pg_dump --no-privileges --no-owner #{Shellwords.escape(local_db_url)} | gzip > #{Shellwords.escape(local_dump)}")
      raise Error.new('local pg_dump failed') unless ok

      step "scp -> #{ctx.host}:#{remote_dump}"
      ctx.ssh.scp_to(local_dump, remote_dump)

      step 'drop + create remote db, restore'
      ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(ctx)}
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \\"$DBNAME\\""
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \\"$DBNAME\\""
        gunzip -c #{Shellwords.escape(remote_dump)} | psql "$DB_URL" -v ON_ERROR_STOP=1
      SH

      ctx.ssh.run("rm -f #{Shellwords.escape(remote_dump)}", allow_fail: true)
      step "done. local copy kept: #{local_dump}"
    end

    # -------- db:pg:transfer ---------------------------------------------

    # Server-to-server copy. Builds two contexts (--from + --server) that
    # share the same local config/deploy/.yaml but point at different
    # hosts. Routes the dump through the local box (./tmp/<app>-xfer-…)
    # so the source and target servers don't need ssh access to each
    # other. Drops + recreates the target DB.
    def db_pg_transfer(opts)
      from = opts[:from].to_s.strip
      raise Error.new('--from HOST is required') if from.empty?

      to_ctx   = Context.build(opts, render: false)
      from_ctx = Context.build(opts.merge(server: from), render: false)
      raise Error.new('--from and --server are the same host') if from_ctx.host == to_ctx.host

      step "db:pg:transfer #{from_ctx.host} -> #{to_ctx.host} (#{to_ctx.app})"
      confirm_pg_destroy!(to_ctx, "OVERWRITE #{to_ctx.host}") unless opts[:yes]

      FileUtils.mkdir_p('./tmp')
      ts         = Time.now.strftime('%Y%m%d-%H%M%S')
      src_dump   = "/tmp/lux-deploy-#{from_ctx.app}-xfer-#{ts}.sql.gz"
      local_dump = "./tmp/#{from_ctx.app}-xfer-#{ts}.sql.gz"
      dst_dump   = "/tmp/lux-deploy-#{to_ctx.app}-xfer-#{ts}.sql.gz"

      step "pg_dump on #{from_ctx.host} -> #{src_dump}"
      from_ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(from_ctx)}
        pg_dump --no-privileges --no-owner "$DB_URL" | gzip > #{Shellwords.escape(src_dump)}
      SH

      step "scp #{from_ctx.host} -> #{local_dump}"
      FileUtils.rm_f(local_dump)
      from_ctx.ssh.scp_from(src_dump, local_dump)
      from_ctx.ssh.run("rm -f #{Shellwords.escape(src_dump)}", as: :service, allow_fail: true)

      step "scp -> #{to_ctx.host}:#{dst_dump}"
      to_ctx.ssh.scp_to(local_dump, dst_dump)

      step "drop + create on #{to_ctx.host}, restore"
      to_ctx.ssh.stream(<<~SH, as: :service)
        #{db_url_preamble(to_ctx)}
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \\"$DBNAME\\""
        psql "$MAINT" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \\"$DBNAME\\""
        gunzip -c #{Shellwords.escape(dst_dump)} | psql "$DB_URL" -v ON_ERROR_STOP=1
      SH

      to_ctx.ssh.run("rm -f #{Shellwords.escape(dst_dump)}", allow_fail: true)
      step "done. local copy kept: #{local_dump}"
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

    def confirm_pg_destroy!(ctx, action)
      $stderr.print "type '#{ctx.domain}' to confirm #{action} on #{ctx.host}: "
      typed = $stdin.gets.to_s.strip
      raise Error.new('aborted; pass --yes to skip prompt') unless typed == ctx.domain
    end

    # Bash preamble shared by every db:pg:* server-side command. Sources
    # the remote .env (so DB_URL is in-shell, never on the ssh argv) then
    # derives:
    #   DBNAME = the database name from $DB_URL
    #   MAINT  = $DB_URL rewritten to point at the `postgres` maintenance
    #            db, used to issue CREATE/DROP DATABASE since you can't
    #            drop the db you're connected to.
    # The sed snippets are intentionally raw (single-quoted heredoc) so
    # Ruby leaves the backreferences and `\n` literal.
    def db_url_preamble(ctx)
      parse = <<~'PARSE'.chomp
        DBNAME=$(printf '%s\n' "$DB_URL" | sed -E 's#.*/([^/?]+)([?].*)?$#\1#')
        MAINT=$(printf '%s\n' "$DB_URL" | sed -E 's#/([^/?]+)([?].*)?$#/postgres\2#')
      PARSE
      "set -a && . #{Shellwords.escape(ctx.app_dir)}/.env && set +a\n#{parse}"
    end

    # systemd unit names. Bare (no .service suffix) since systemctl accepts both.
    def web_unit(ctx) = "#{ctx.config.service_prefix}-#{ctx.app}"
    def job_unit(ctx) = "#{ctx.config.job_service_prefix}-#{ctx.app}"

    def ensure_remote_dirs(ctx)
      step 'ensure remote dirs'
      ctx.ssh.run(<<~SH, as: :service)
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/tmp
        mkdir -p #{Shellwords.escape(ctx.app_dir)}/shared/log
      SH
    end

    def allocate_port(ctx)
      step 'allocate port'
      # Read PORT from existing .env if present (re-deploys reuse it)
      existing = ctx.ssh.run(
        "[ -f #{Shellwords.escape(ctx.app_dir)}/.env ] && " \
        "grep -E '^PORT=' #{Shellwords.escape(ctx.app_dir)}/.env || true",
        as: :service, allow_fail: true
      ).strip
      if existing =~ /^PORT=(\d+)/
        port = $1.to_i
        $stderr.puts "    reusing existing PORT=#{port}"
        return port
      end

      # Scan free port from PORT_RANGE
      in_use = ctx.ssh.run("ss -tlnH | awk '{print $4}' | sed 's/.*://'", allow_fail: true)
        .lines.map { |l| l.strip.to_i }.to_set
      free = PORT_RANGE.find { |p| !in_use.include?(p) }
      raise Error.new("no free port in 3010..3990 (step 10)") unless free
      $stderr.puts "    allocated PORT=#{free}"
      free
    end

    # Two-pass render:
    #   1. compose base vars (git + yaml + plugin-provided), render .env
    #   2. parse .env, merge result into vars (env overrides yaml so staging
    #      branches can redefine DOMAIN), render the remaining templates.
    def render_artifacts(ctx)
      step 'render templates'

      base_vars = ctx.base_vars.merge(
        PORT:     ctx.port,
        DIR:      ctx.app_dir,
        RUBY:     ctx.ruby_path,
        RUBY_DIR: File.dirname(ctx.ruby_path)
      )

      env_rendered = Template.render(ctx.read_template(ctx.env_template_name), base_vars)
      env_hash     = Template.parse_env(env_rendered)

      all_vars = base_vars.merge(env_hash)
      ctx.domain = (env_hash[:DOMAIN] || base_vars[:DOMAIN]).to_s
                    .split(',').first.to_s.strip.sub(/^\*\./, '')
      raise Error.new('DOMAIN resolved to empty') if ctx.domain.empty?

      ctx.rendered = {
        '.env'            => env_rendered,
        'caddy.config'    => Template.render(ctx.read_template('caddy.conf'), all_vars),
        'systemd.service' => Template.render(ctx.read_template('systemd.service'), all_vars)
      }
      if ctx.job_template?
        ctx.rendered['systemd.job.service'] = Template.render(ctx.read_template('job.service'), all_vars)
      end
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

    BEFORE_LOCAL_HOOK ||= 'config/deploy/before_local.sh'
    AFTER_SERVER_HOOK ||= 'config/deploy/after_server.sh'

    # Pre-flight gate. Runs locally in the project root before any remote
    # work. Optional - skipped silently if the file isn't in the repo.
    # Non-zero exit aborts the deploy.
    def run_before_local_hook(ctx)
      return unless File.exist?(BEFORE_LOCAL_HOOK)
      step "run #{BEFORE_LOCAL_HOOK} (local)"
      if ctx.ssh.dry_run
        $stderr.puts "  [dry] bash #{BEFORE_LOCAL_HOOK}"
        return
      end
      system('bash', BEFORE_LOCAL_HOOK) or
        raise Error.new("#{BEFORE_LOCAL_HOOK} failed; deploy aborted (no remote state changed)")
    end

    # Post-deploy hook. Runs on the server inside release/ after the swap
    # and service reload. Optional - skipped silently if absent. Non-zero
    # exit warns but does NOT roll back (deploy is already live).
    def run_after_server_hook(ctx)
      return unless File.exist?(AFTER_SERVER_HOOK)
      step "run #{AFTER_SERVER_HOOK} (server)"
      ok = ctx.ssh.stream(
        "cd #{Shellwords.escape(ctx.app_dir)}/release && bash #{Shellwords.escape(AFTER_SERVER_HOOK)}",
        as: :service, allow_fail: true
      )
      warn "#{AFTER_SERVER_HOOK} failed but deploy is already live; continuing" unless ok
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
      web_unit = web_unit(ctx)
      ctx.ssh.run(<<~SH)
        install -d #{CADDY_SITES} #{SYSTEMD_DIR}
        ln -sfn #{Shellwords.escape(ctx.app_dir)}/systemd.service #{SYSTEMD_DIR}/#{web_unit}.service
        ln -sfn #{Shellwords.escape(ctx.app_dir)}/caddy.config    #{CADDY_SITES}/#{ctx.app}.caddy
      SH

      if ctx.job_template?
        job_unit = job_unit(ctx)
        ctx.ssh.run(<<~SH)
          ln -sfn #{Shellwords.escape(ctx.app_dir)}/systemd.job.service #{SYSTEMD_DIR}/#{job_unit}.service
        SH
      end
    end
  end
end
