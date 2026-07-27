require 'fileutils'
require 'open3'
require 'shellwords'

module LuxDeploy
  # Always connects as root. To run as the service user pass `as: :service`
  # which wraps the command in `sudo -iu <service_user> bash -lc <quoted>`
  # so the login shell activates mise (PATH for ruby/bundler).
  class SSH
    attr_reader :host, :dry_run, :service_user

    # Silences the per-command echo. Only the TUI sets it: that echo goes to
    # stderr, which shares the terminal it is drawing on, so every refresh
    # scribbled over the screen.
    attr_accessor :quiet

    # A deploy makes 15-20 remote calls; without multiplexing each one pays a
    # full TCP + auth handshake. %C hashes the connection tuple, which keeps
    # the socket path under the sun_path length limit.
    CONTROL_PATH ||= '~/.ssh/lux-deploy-%C'

    def initialize(host, service_user: 'deployer', dry_run: false)
      raise Error.new('config/deploy/.yaml server: is empty') if host.to_s.strip.empty?
      @host = host.to_s.strip.sub(/^.*@/, '')
      @service_user = service_user
      @dry_run = dry_run
      @multiplex = control_dir_available?
    end

    # Run a command. Returns stdout (always captured).
    # On non-zero exit raises unless allow_fail: true (then returns whatever was captured).
    def run(cmd, as: :root, allow_fail: false)
      remote = wrap(cmd, as)
      argv = ssh_argv + [remote]
      log argv, cmd
      return '' if dry_run
      out, status = Open3.capture2e(*argv)
      if !status.success? && !allow_fail
        raise Error.new("ssh failed (exit #{status.exitstatus})\n--- remote stderr+stdout ---\n#{out}")
      end
      out
    end

    # Streamed run (stdout/stderr pass through). Use for long-running steps
    # the user wants to watch (bundle install, verification hooks).
    def stream(cmd, as: :root, allow_fail: false)
      remote = wrap(cmd, as)
      argv = ssh_argv + [remote]
      log argv, cmd
      return true if dry_run
      ok = system(*argv)
      raise Error.new("ssh failed: #{cmd}") if !ok && !allow_fail
      ok
    end

    # rsync local dir to remote path; runs receiver as service user via sudo.
    def rsync(src, dest_path, excludes: [])
      argv = [
        'rsync', '-az', '--delete',
        '-e', (['ssh'] + control_opts).join(' '),
        *excludes.flat_map { |e| ['--exclude', e] },
        "--rsync-path=sudo -u #{service_user} rsync",
        src, "root@#{host}:#{dest_path}"
      ]
      log argv, "rsync #{src} -> #{dest_path}"
      return if dry_run
      system(*argv) or raise Error.new('rsync failed')
    end

    # Interactive ssh that allocates a TTY and replaces the current process
    # (via Process.exec). Use for shells, REPLs, psql - anything that needs
    # job control. Does not return on success.
    def exec(cmd, as: :root)
      remote = wrap(cmd, as, interactive: true)
      argv = ssh_argv(interactive: true) + [remote]
      log argv, cmd
      return if dry_run
      Process.exec(*argv)
    end

    # scp a file from the remote (as root) to a local path.
    def scp_from(remote_path, local_path)
      argv = ['scp', *control_opts, '-o', 'StrictHostKeyChecking=accept-new',
              "root@#{host}:#{remote_path}", local_path]
      log argv, "scp #{remote_path} -> #{local_path}"
      return if dry_run
      system(*argv) or raise Error.new("scp failed: #{remote_path}")
    end

    # scp a local file up to the remote (as root). Default umask leaves
    # the file 0644 so the service user can read it from /tmp.
    def scp_to(local_path, remote_path)
      argv = ['scp', *control_opts, '-o', 'StrictHostKeyChecking=accept-new',
              local_path, "root@#{host}:#{remote_path}"]
      log argv, "scp #{local_path} -> #{remote_path}"
      return if dry_run
      system(*argv) or raise Error.new("scp failed: #{local_path}")
    end

    private

    def ssh_argv(interactive: false)
      [
        'ssh',
        *(interactive ? ['-tt'] : ['-o', 'BatchMode=yes']),
        *control_opts,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=10',
        "root@#{host}"
      ]
    end

    def control_opts
      return [] unless @multiplex
      ['-o', 'ControlMaster=auto',
       '-o', "ControlPath=#{CONTROL_PATH}",
       '-o', 'ControlPersist=60s']
    end

    # Multiplexing is an optimization, never a requirement: without a usable
    # ~/.ssh (no HOME, read-only home, a container/cron user) we simply don't
    # ask for it rather than failing every command.
    def control_dir_available?
      FileUtils.mkdir_p(File.expand_path('~/.ssh'), mode: 0o700)
      true
    rescue SystemCallError, ArgumentError
      false
    end

    def wrap(cmd, as, interactive: false)
      case as
      when :root then cmd
      when :service, :deployer
        if interactive
          # Interactive shells need a TTY on stdin, so we can't use the
          # base64-pipe transport (it leaves bash reading from a closed pipe
          # and the inner `exec bash -li` exits immediately). Single-line
          # commands don't need the b64 dance anyway - just shell-escape.
          "sudo -iu #{service_user} -- bash -lc #{Shellwords.escape(cmd)}"
        else
          # sudo -i backslash-escapes every shell metachar including newlines, so
          # multi-line scripts get collapsed by the target shell (\<nl> = line
          # continuation). Transport the script base64-encoded so no metachars
          # survive into the service user's shell re-parse.
          b64 = [cmd].pack('m0')
          inner = "echo #{b64} | base64 -d | bash -l"
          "sudo -iu #{service_user} bash -lc #{Shellwords.escape(inner)}"
        end
      else raise "unknown ssh user: #{as}"
      end
    end

    def log(_argv, summary)
      return if quiet
      prefix = dry_run ? '  [dry] ' : '  $ '
      head = summary.lines.first.to_s.chomp
      head += ' …' if summary.lines.count > 1
      $stderr.puts "\e[2m#{prefix}#{head}\e[0m"
    end
  end
end
