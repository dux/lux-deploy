module LuxDeploy
  # Registers the lux-deploy Hammer tasks on a host CLI. Designed to be
  # called from a Hammerfile (the gem's own, the lux-fw plugin's, or any
  # user's) so all task definitions live in one place.
  #
  # Usage from a Hammerfile (block DSL):
  #
  #   require 'lux_deploy'
  #   LuxDeploy::Hammer.register(self)                            # top-level
  #   LuxDeploy::Hammer.register(self, prefix: :deploy)           # under deploy:
  #   LuxDeploy::Hammer.register(self,
  #     prefix: :deploy,
  #     templates_dir: '/abs/path/to/plugin/templates',
  #     defaults: {
  #       service_prefix: 'lux-web',
  #       remote_base: '/home/deployer/lux-apps',
  #     }
  #   )
  #
  # `defaults` is merged under user's .yaml (yaml wins). `templates_dir`
  # is what `app:init` copies from and the deploy step falls back to
  # when ./config/deploy/<name> is missing.
  module Hammer
    module_function

    def safe(opts)
      yield
    rescue LuxDeploy::Error => e
      warn e.to_s
      exit 1
    rescue Interrupt
      warn 'aborted'
      exit 130
    end

    def register(receiver, prefix: nil, templates_dir: nil, defaults: nil)
      LuxDeploy.set_defaults(defaults) if defaults
      tdir = templates_dir
      if prefix
        receiver.namespace(prefix) { LuxDeploy::Hammer.define_on(self, tdir) }
      else
        define_on(receiver, tdir)
      end
    end

    # `target` must respond to `task` and `namespace` (Builder or Hammer
    # subclass). `tdir` is captured by task closures so `app:init` and
    # deploy template fallback both see it.
    def define_on(target, tdir)
      target.task :up do
        desc 'Deploy current branch (rsync, hooks, swap, restart)'
        opt :server,  desc: 'Override hostname from config/deploy/.yaml'
        opt :dry_run, type: :boolean, default: false, desc: 'Print commands, do not execute'

        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.up(opts.merge(templates_dir: tdir)) } }
      end

      target.task :redeploy do
        desc 'Destroy then deploy (fresh PORT, blank release history)'
        opt :server,  desc: 'Override hostname from config/deploy/.yaml'
        opt :yes,     type: :boolean, default: false, desc: 'Skip destroy confirmation'
        opt :dry_run, type: :boolean, default: false, desc: 'Print commands, do not execute'

        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.redeploy(opts.merge(templates_dir: tdir)) } }
      end

      target.task :destroy do
        desc 'Stop service, unlink caddy/systemd, remove app dir'
        opt :server,  desc: 'Override hostname from config/deploy/.yaml'
        opt :yes,     type: :boolean, default: false, desc: 'Skip type-domain-to-confirm prompt'
        opt :dry_run, type: :boolean, default: false, desc: 'Print commands, do not execute'

        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.destroy(opts.merge(templates_dir: tdir)) } }
      end

      target.task :doctor do
        desc 'Check & prepare host: service user, dirs, caddy, ruby, bundler'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        opt :fix,    type: :boolean, default: true, desc: 'Auto-fix safe items (default true; --no-fix to skip)'

        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.doctor(opts) } }
      end

      target.task :log do
        desc 'List server logs, or dump one with --log <name> (--lines 200)'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        opt :log,    desc: 'Log name to dump (e.g. errors, exceptions); omit to list all logs'
        opt :lines,  default: 200, desc: 'Lines to show when dumping a log (default 200)'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.log(opts.merge(templates_dir: tdir)) } }
      end

      target.namespace(:app)    { LuxDeploy::Hammer.define_app_on(self, tdir) }
      target.namespace(:server) { LuxDeploy::Hammer.define_server_on(self, tdir) }
      target.namespace(:on)     { LuxDeploy::Hammer.define_on_hooks_on(self, tdir) }
    end

    def define_on_hooks_on(target, tdir)
      target.namespace(:remote) do
        LuxDeploy::Hammer.define_hook_task_on(self, :before, :remote, :before, tdir, 'Run config/deploy/remote_before.sh on new-release/')
        LuxDeploy::Hammer.define_hook_task_on(self, :after, :remote, :after, tdir, 'Run config/deploy/remote_after.sh on release/')
      end

      target.namespace(:local) do
        LuxDeploy::Hammer.define_hook_task_on(self, :before, :local, :before, tdir, 'Run config/deploy/local_before.sh locally')
        LuxDeploy::Hammer.define_hook_task_on(self, :after, :local, :after, tdir, 'Run config/deploy/local_after.sh locally')
      end
    end

    def define_hook_task_on(target, task_name, side, timing, tdir, description)
      target.task task_name do
        desc description
        opt :server,  desc: 'Override hostname from config/deploy/.yaml'
        opt :dry_run, type: :boolean, default: false, desc: 'Print commands, do not execute'

        proc { |opts|
          LuxDeploy::Hammer.safe(opts) {
            LuxDeploy::Commands.hook(opts.merge(templates_dir: tdir), side, timing)
          }
        }
      end
    end

    def define_app_on(target, tdir)
      target.task :init do
        desc 'Copy shipped templates into ./config/deploy/ (skips existing files)'
        opt :from, desc: 'Override templates directory (default: caller-provided or bundled)'
        proc { |opts|
          LuxDeploy::Hammer.safe(opts) {
            LuxDeploy::Commands.init(opts.merge(templates_dir: opts[:from] || tdir))
          }
        }
      end
    end

    def define_server_on(target, tdir)
      target.task :ssh do
        desc 'SSH into the release folder as the service user'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.server_ssh(opts.merge(templates_dir: tdir)) } }
      end

      target.task :log do
        desc 'Tail systemd journal for the web service (-f, last 200)'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.server_log(opts.merge(templates_dir: tdir)) } }
      end

      target.task :errors do
        desc 'Tail -f the app error log (release/log/error.log)'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.server_errors(opts.merge(templates_dir: tdir)) } }
      end

      target.task :restart do
        desc 'systemctl restart the web service'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.server_restart(opts.merge(templates_dir: tdir)) } }
      end

      target.task :status do
        desc 'systemctl status the web service'
        opt :server, desc: 'Override hostname from config/deploy/.yaml'
        proc { |opts| LuxDeploy::Hammer.safe(opts) { LuxDeploy::Commands.server_status(opts.merge(templates_dir: tdir)) } }
      end
    end

  end
end
