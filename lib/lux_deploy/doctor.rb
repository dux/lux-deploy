require 'yaml'

module LuxDeploy
  # Named host checks: each entry is [label, check_cmd, fix_cmd_or_nil].
  # `check_cmd` must exit 0 on PASS, non-zero on FAIL.
  # `fix_cmd` is optional; if present and check fails, we run it (when --fix)
  # and re-check. Anything that needs interactive judgement leaves fix_cmd nil.
  module Doctor
    GREEN  ||= "\e[32m"
    RED    ||= "\e[31m"
    YELLOW ||= "\e[33m"
    DIM   ||= "\e[2m"
    RESET ||= "\e[0m"

    # Placeholders the engine always provides at deploy time; templates
    # may reference these without declaring them in .env or .yaml.
    PROVIDED_VARS ||= %w[
      GIT_BRANCH GIT_BRANCH_UNDERSCORE GIT_BRANCH_SLUG GIT_COMMIT GIT_COMMIT_SHORT
      APP APP_UNDERSCORE APP_DOMAIN DOMAIN HASH TAG
      PORT DIR RUBY RUBY_DIR LOG_DIR LOG_NAME SERVICE_USER SERVICE_HOME
    ].freeze

    module_function

    def run(ssh, config, fix: true, dry_run: false)
      puts 'Local config'
      local_failed = local_checks(config)
      puts

      checks = build_checks(config)

      # A dry run still does the local checks for real (they touch nothing) and
      # prints the remote probes it would run, rather than reporting every
      # remote check as failed because nothing was executed.
      if dry_run
        puts 'Remote host (dry run - not executed)'
        checks.each do |label, check_cmd, fix_cmd|
          puts "  #{DIM}CHECK#{RESET} #{label}"
          puts "  #{DIM}        #{check_cmd.lines.first.chomp}#{RESET}"
          puts "  #{DIM}        fix: #{fix_cmd.lines.first.chomp}#{RESET}" if fix && fix_cmd
        end
        puts
        raise Error.new("doctor reported #{local_failed} local failure(s)") unless local_failed.zero?
        return
      end

      puts 'Remote host'
      failed = local_failed

      checks.each do |label, check_cmd, fix_cmd|
        if passes?(ssh, check_cmd)
          puts "  #{GREEN}PASS#{RESET}  #{label}"
          next
        end

        if fix && fix_cmd
          puts "  #{DIM}FIX#{RESET}   #{label}"
          ssh.run(fix_cmd, allow_fail: true)
          if passes?(ssh, check_cmd)
            puts "  #{GREEN}PASS#{RESET}  #{label} (after fix)"
            next
          end
        end

        failed += 1
        puts "  #{RED}FAIL#{RESET}  #{label}"
        puts "  #{DIM}        check: #{check_cmd.lines.first.chomp}#{RESET}"
      end

      puts
      if failed.zero?
        puts "#{GREEN}all checks passed#{RESET}"
      else
        puts "#{RED}#{failed} check#{failed == 1 ? '' : 's'} failed#{RESET}"
        raise Error.new("doctor reported #{failed} failure(s)")
      end
    end

    # Run check command, return true on exit 0.
    def passes?(ssh, cmd)
      out = ssh.run(cmd + ' && echo __OK__ || echo __FAIL__', allow_fail: true)
      out.include?('__OK__')
    end

    # Lifecycle hooks (run during `up` if present in config/deploy/).
    # Optional - doctor reports their presence/absence, never creates.
    # Scaffolds with explanatory header comments ship via `app:init`.
    HOOK_FILES ||= %w[local_before.sh remote_before.sh remote_after.sh local_after.sh
                      health.sh].freeze

    # True when any local config/deploy template references {{RUBY}}. Gates
    # the ruby/bundler host checks so a Go/Python app doesn't fail doctor.
    def ruby_runtime?(dir = './config/deploy')
      Dir.glob("#{dir}/*").any? { |f| File.file?(f) && File.read(f).include?('{{RUBY') }
    end

    # True when a unit template drives containers - gates the docker host
    # checks so every other app is unaffected.
    #
    # Only *.service files, and never a "!"-disabled one: those are switched
    # off everywhere else in the engine, so a !docker.service someone parked
    # must not make doctor start demanding a docker daemon.
    def docker?(dir = './config/deploy')
      Dir.glob("#{dir}/*.service")
         .reject { |f| File.basename(f).start_with?('!') }
         .any? { |f| File.file?(f) && File.read(f).match?(/\b(docker|podman)\b/) }
    end

    # True when caddy.conf emits a JSON access log - gates the bun/importer
    # host checks so apps without access logging don't fail doctor.
    def caddy_log?(dir = './config/deploy')
      f = "#{dir}/caddy.conf"
      File.exist?(f) && File.read(f).include?('.jsonl')
    end

    # True when git ignores the path. Outside a git repo there is nothing to
    # leak into, so treat it as fine rather than failing the check.
    def gitignored?(path)
      return true unless system('git', 'rev-parse', '--git-dir', out: File::NULL, err: File::NULL)
      system('git', 'check-ignore', '-q', path, out: File::NULL, err: File::NULL)
    end

    def local_checks(_config)
      dir = './config/deploy'
      failed = 0

      report = ->(ok, label, detail = nil) {
        if ok
          puts "  #{GREEN}PASS#{RESET}  #{label}"
        else
          failed += 1
          puts "  #{RED}FAIL#{RESET}  #{label}"
          puts "  #{DIM}        #{detail}#{RESET}" if detail
        end
      }

      skip = ->(label) { puts "  #{DIM}SKIP  #{label} (does not exist)#{RESET}" }

      # Advice, not a verdict - these are habits worth flagging but not
      # reasons to block a deploy, so they never count toward `failed`.
      nag = ->(ok, label, detail) {
        if ok
          puts "  #{GREEN}PASS#{RESET}  #{label}"
        else
          puts "  #{YELLOW}WARN#{RESET}  #{label}"
          puts "  #{DIM}        #{detail}#{RESET}"
        end
      }

      unless Dir.exist?(dir)
        report.call(false, "#{dir}/ directory present",
                    "missing; run: lux-deploy app:init")
        return failed
      end

      # Parse .yaml; bail early if absent or malformed since other
      # checks depend on its keys.
      yaml_path = "#{dir}/.yaml"
      yaml_data = nil
      if File.exist?(yaml_path)
        report.call(true, "#{yaml_path} present")
        begin
          yaml_data = YAML.safe_load(File.read(yaml_path)) || {}
          report.call(yaml_data.is_a?(Hash), "#{yaml_path} is a YAML mapping")
          yaml_data = {} unless yaml_data.is_a?(Hash)
          report.call(!yaml_data['server'].to_s.strip.empty?, ".yaml 'server:' set")
          report.call(!yaml_data['domain'].to_s.strip.empty?, ".yaml 'domain:' set")
        rescue Psych::SyntaxError => e
          report.call(false, "#{yaml_path} parses", e.message)
          yaml_data = {}
        end
      else
        report.call(false, "#{yaml_path} present", "missing; run: lux-deploy app:init")
        yaml_data = {}
      end

      # One env template per branch: .env.main serves master/main, .env.default
      # every other branch, .env.<branch> wins for one specific branch.
      env_files = Dir.children(dir).sort.select do |f|
        f.start_with?('.env') && f != '.env.local' && File.file?(File.join(dir, f))
      end
      report.call(env_files.any?, "#{dir}/.env.* template present",
                  'expected at least .env.main or .env.default; run: lux-deploy app:init')
      report.call(File.exist?("#{dir}/caddy.conf"),      "#{dir}/caddy.conf present")
      report.call(File.exist?("#{dir}/systemd.service"), "#{dir}/systemd.service present")

      # These are rendered fresh on every deploy, so anything real in them is a
      # secret living in the repo. Server-side values belong in
      # <app_dir>/.env.local (see `lux-deploy env:set`).
      env_files.each do |name|
        path = "#{dir}/#{name}"
        nag.call(!File.read(path).include?('replace-me'), "#{name} has no leftover replace-me values",
                 'set it on the server instead: lux-deploy env:set SECRET=$(openssl rand -hex 32)')
        nag.call(gitignored?(path), "#{path} is gitignored",
                 "it can hold secrets; add #{path} to .gitignore")
      end

      # A local .env.local does nothing - the overlay lives on the server, at
      # <app_dir>/.env.local. Silently ignoring it would look like data loss.
      nag.call(!File.exist?("#{dir}/.env.local"), "no stray #{dir}/.env.local",
               'the env overlay lives on the server; use lux-deploy env:set / env:edit')

      # Lifecycle hooks - optional. Report each as PASS (present, will run)
      # or SKIP (absent, hook step will be skipped during `up`).
      HOOK_FILES.each do |name|
        path = "#{dir}/#{name}"
        if File.exist?(path)
          report.call(true, "#{path} present (will run)")
        else
          skip.call("#{path} (lifecycle hook)")
        end
      end

      yaml_keys = yaml_data.keys.map { |k| k.to_s.upcase }

      # Every template is rendered with the same vars: engine-provided +
      # yaml. The rendered .env is uploaded verbatim; it never feeds back
      # into the template namespace, so caddy.conf / *.service can only
      # reference yaml keys + engine vars (not anything defined in .env).
      # Every *.service file is a service; only systemd.service is required.
      # PORT-prefixed placeholders are engine-provided (auto-allocated).
      service_files       = Dir.children(dir).select { |f| f.end_with?('.service') && !f.start_with?('!') }.sort
      optional            = env_files + (service_files - %w[systemd.service])
      placeholder_targets = env_files + %w[caddy.conf] + service_files
      provided            = PROVIDED_VARS + yaml_keys
      placeholder_targets.uniq.each do |name|
        path = "#{dir}/#{name}"
        unless File.exist?(path)
          skip.call(name) if optional.include?(name)
          next
        end

        placeholders = File.read(path).scan(Template::PLACEHOLDER).flatten.uniq
        missing      = placeholders.reject { |v| provided.include?(v) || v.start_with?('PORT') }
        ok           = missing.empty?
        report.call(ok, "#{name}: placeholders resolve",
                    ok ? nil : "missing: #{missing.map { |v| "{{#{v}}}" }.join(' ')}")
      end

      failed
    end

    def build_checks(config)
      user = config.service_user
      base = config.remote_base
      [
        [
          "#{user} user exists",
          "id #{user} >/dev/null 2>&1",
          "useradd -m -s /bin/bash #{user}"
        ],
        [
          "/home/#{user} is traversable (0755)",
          # caddy + systemd need to read symlinks into ~/<base>;
          # useradd defaults home to 0700 on Debian, which blocks them.
          "[ \"$(stat -c %a /home/#{user})\" = 755 ]",
          "chmod 0755 /home/#{user}"
        ],
        [
          "#{user} in sudo group (passwordless)",
          "grep -q '^#{user} ' /etc/sudoers.d/#{user} 2>/dev/null && grep -q NOPASSWD /etc/sudoers.d/#{user}",
          "echo '#{user} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/#{user} && chmod 0440 /etc/sudoers.d/#{user}"
        ],
        [
          "#{base} exists and owned by #{user}",
          "[ -d #{base} ] && [ \"$(stat -c %U #{base})\" = #{user} ]",
          "install -d -o #{user} -g #{user} -m 0755 #{base}"
        ],
        [
          '/etc/caddy/sites exists',
          "[ -d #{CADDY_SITES} ]",
          "install -d -m 0755 #{CADDY_SITES}"
        ],
        [
          'caddy running',
          'systemctl is-active --quiet caddy',
          nil
        ],
        [
          "caddy imports #{CADDY_SITES}/*.caddy",
          "grep -Rq 'import #{CADDY_SITES}/\\*.caddy' /etc/caddy/ 2>/dev/null",
          nil
        ],
        [
          "mise installed for #{user}",
          "sudo -iu #{user} bash -lc 'command -v mise >/dev/null'",
          nil
        ],
        # Ruby/bundler only matter when a template references {{RUBY}};
        # a Go/Python app builds in remote_before and needs neither.
        *(ruby_runtime? ? [
          [
            "ruby on #{user} PATH",
            "sudo -iu #{user} bash -lc 'command -v ruby >/dev/null && ruby -v'",
            nil
          ],
          [
            "bundler on #{user} PATH",
            "sudo -iu #{user} bash -lc 'command -v bundle >/dev/null'",
            "sudo -iu #{user} bash -lc 'gem install bundler --no-document'"
          ]
        ] : []),
        # Containers: only when a unit template actually drives one.
        *(docker? ? [
          [
            'docker installed',
            'command -v docker >/dev/null && docker --version',
            nil
          ],
          [
            'docker daemon running',
            'systemctl is-active --quiet docker',
            nil
          ],
          # No fix command on purpose. Membership here is root-equivalent on
          # this host, and doctor applies fixes on its own; granting that
          # during a routine check is not the engine's call to make.
          # `lux-deploy prepare:docker` is the explicit opt-in.
          [
            "#{user} in the docker group (run prepare:docker to grant)",
            "id -nG #{user} | grep -qw docker",
            nil
          ],
          # The one that matches reality: the group only applies to a new
          # login session, and every remote step runs through `sudo -iu`.
          [
            "docker reachable as #{user}",
            "sudo -iu #{user} bash -lc 'docker info >/dev/null 2>&1'",
            nil
          ]
        ] : []),
        # Access-log ingestion: only when this app emits a JSON access log.
        *(caddy_log? ? [
          [
            "bun installed for #{user}",
            "sudo -iu #{user} bash -lc '[ -x ~/.bun/bin/bun ]'",
            nil
          ],
          [
            "caddy-log importer present (#{IMPORTER_REMOTE})",
            "[ -f #{IMPORTER_REMOTE} ]",
            nil
          ],
          [
            "caddy-log importer service running (#{IMPORTER_UNIT})",
            "systemctl is-active --quiet #{IMPORTER_UNIT}",
            nil
          ]
        ] : []),
        [
          'xcaddy available (for plugin rebuilds)',
          'command -v xcaddy >/dev/null',
          nil
        ],
        [
          'ssh password auth disabled (warn-only)',
          "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'",
          nil
        ]
      ]
    end
  end
end
