# lux-deploy

Stupid-simple deploy via SSH + rsync. No Docker. No registry. No JSON.

Caddy + systemd + atomic-release deploys. The whole behavior surface lives
in **one yaml file** (`config/deploy/.yaml`). No adapter classes, no
plugins to register - host defaults are baked into the gem, anything
app-specific goes in the yaml.

## Install

```sh
gem install lux-deploy
```

Or in a Gemfile:

```ruby
gem 'lux-deploy'
```

## Quick start

```sh
bundle exec lux-deploy app:init     # copy starter templates into ./config/deploy/
$EDITOR config/deploy/.yaml          # set server: and domain:
$EDITOR config/deploy/systemd.service # set your ExecStart
bundle exec lux-deploy doctor        # prep + check the host
bundle exec lux-deploy up            # ship it
```

## Configuration: `config/deploy/.yaml`

Required:

```yaml
server:        srv.example.com
domain:        example.com
smoke_command: bundle exec ruby -e "puts 'ok'"   # see "Smoke" below
```

Optional (defaults shown):

```yaml
service_user:       deployer                # unix user that owns the app dir
remote_base:        /home/deployer/apps     # ~/<remote_base>/<app>/
service_prefix:     web                     # systemd unit: <prefix>-<app>.service
job_service_prefix:                         # nil = no job service
```

Any other key becomes an UPPERCASE `{{KEY}}` placeholder available to every
template under `config/deploy/`.

### Smoke

`smoke_command` runs inside `new-release/` after `bundle install` and
before the atomic swap. Exit 0 = release goes live; non-zero = roll back
(`new-release/` is wiped, the previous `release/` keeps serving).

It is **mandatory**. There is no "skip" — the entire point of the deploy
gate is to be unskippable. The command can be anything that exits with a
proper code: a ruby boot-eval, an rspec invocation, a shell script, a
python test, a `curl` against a sidecar, whatever. Examples:

```yaml
smoke_command: bundle exec lux e 1                  # lux: boot framework, eval 1
smoke_command: bundle exec rails runner "puts 1"    # rails: boot app
smoke_command: bundle exec rspec spec/smoke         # tagged smoke specs
smoke_command: bundle exec rake smoke               # custom rake task
smoke_command: ./bin/smoke                          # shell script
smoke_command: pytest tests/smoke                   # not even ruby
```

If your smoke needs gems excluded by `--without 'development test'`,
either move them into a different bundler group or write your smoke to
not depend on them.

### Lifecycle hooks: `before_local.sh` / `after_server.sh`

Optional scripts in `config/deploy/`. The filename suffix is the contract:
`_local` runs on your machine, `_server` runs on the production box.
Skipped silently when absent. `app:init` ships empty scaffolds with
explanatory header comments; `doctor` reports which are present.

| file | where | when | failure |
| --- | --- | --- | --- |
| `before_local.sh` | local repo root | before any remote work (right after context build) | abort - no remote state changed |
| `after_server.sh` | server `release/` | after atomic swap, service reload, job restart | warn - new release is already live |

Lives in the repo, rsync'd to the server with everything else. The server
has no special awareness of these files - lux-deploy itself runs the
named hook on the named side. `before_local.sh` ends up on the server too
but is never executed there.

### Wrapping lux-deploy from another gem / Hammerfile

A wrapping plugin (e.g. lux-fw's `plugins/deploy/`) can seed defaults that
sit *under* the user's `.yaml`:

```ruby
LuxDeploy::Hammer.register(
  self,
  prefix:        :deploy,
  templates_dir: File.expand_path('templates', __dir__),
  defaults: {
    service_prefix:     'lux-web',
    job_service_prefix: 'lux-job',
    remote_base:        '/home/deployer/lux-apps',
    smoke_command:      'bundle exec lux e 1'
  }
)
```

Precedence: user `.yaml` > plugin `defaults` > engine defaults.

## Commands

| command                | purpose |
| ---------------------- | ------- |
| `lux-deploy up`        | deploy current branch |
| `lux-deploy redeploy`  | destroy + deploy (fresh PORT) |
| `lux-deploy destroy`   | stop service, unlink caddy/systemd, remove `~/<remote_base>/<app>` |
| `lux-deploy doctor`    | check & prepare host (deployer user, dirs, caddy, ruby, bundler) |
| `lux-deploy app:init`  | copy bundled templates into `./config/deploy/` |
| `lux-deploy server:ssh`     | open a shell on the release dir |
| `lux-deploy server:log`     | tail the systemd journal |
| `lux-deploy server:restart` | restart the web service |
| `lux-deploy server:status`  | systemd status |
| `lux-deploy db:psql`        | open remote psql via DB_URL |
| `lux-deploy db:pull`        | alias of `db:pg:pull` |
| `lux-deploy db:pg:check`    | print remote DB info: name, size, public table count, version |
| `lux-deploy db:pg:create`   | `CREATE DATABASE` for the dbname in remote `.env DB_URL` |
| `lux-deploy db:pg:destroy`  | `DROP DATABASE` on remote (type-domain to confirm) |
| `lux-deploy db:pg:backup`   | `pg_dump` remote -> `./tmp/<app>-<ts>.sql.gz` |
| `lux-deploy db:pg:pull`     | `pg_dump` remote, restore into local `$DB_URL` |
| `lux-deploy db:pg:push`     | `pg_dump` local `$DB_URL`, restore into remote (type-domain to confirm) |
| `lux-deploy db:pg:transfer` | server-to-server: `--from HOST` -> `--server` via local relay (type-domain to confirm) |

Common flags:

* `--server HOST` -- override `config/deploy/.yaml: server:`
* `--dry-run`     -- print commands, no remote changes
* `--yes`         -- skip `destroy` confirmation
* `--no-fix`      -- `doctor` reports only, no auto-fix

## Project layout (in your app)

```
config/deploy/
  .yaml                  # server: + domain: + any overrides + custom {{KEY}}s
  .env                   # production env (used on master/main)
  .env.staging           # staging env (used on any other branch)
  caddy.conf             # caddy site file
  systemd.service        # systemd unit for the web server
  job.service            # optional: systemd unit for the job runner
```

The two required keys are `server` and `domain`. Any additional key
becomes an UPPERCASE `{{KEY}}` placeholder available to every template
(e.g. add `cdn: cdn.example.com` and use `{{CDN}}` in caddy.conf).

## Server layout

```
<remote_base>/<app>/
  release/                 # current code + bundle
    tmp -> ../shared/tmp
    log -> ../shared/log
    .env -> ../.env
  old-release/             # previous release, kept one cycle
  shared/
    tmp/                   # survives release swap
    log/                   # survives release swap
  .env                     # rendered, PORT lives here (0600)
  systemd.service          # rendered; linked into /etc/systemd/system/<prefix>-<app>.service
  caddy.config             # rendered; linked into /etc/caddy/sites/<app>.caddy
  systemd.job.service      # optional; linked into /etc/systemd/system/<job-prefix>-<app>.service
  lux-deploy.yaml          # post-deploy manifest, mode 0644 (see below)
```

`<app>` is the first comma-separated value of `DOMAIN` from the rendered
`.env` (falls back to `.yaml`'s `domain:`; wildcards stripped: `*.foo` -> `foo`).

## Manifest: `lux-deploy.yaml`

Every successful `up` writes a `lux-deploy.yaml` next to `.env` on the
remote. It is a self-describing snapshot of what is wired up: services,
unit names, caddy paths, allocated port, git commit, ExecStart lines,
non-secret env values, and a few ready-to-paste shell helpers
(`systemctl restart ...`, `journalctl -u ...`, `systemctl reload caddy`).

It is mode 0644 and never contains secrets: any key matching
`SECRET / PASSWORD / TOKEN / KEY / DB_URL / DATABASE_URL / CREDENTIAL`
keeps its name but its value is replaced with `<redacted>`.

Intended consumers: humans, LLMs, monitoring scripts, future lux-deploy
commands. Regenerated on every deploy, removed with the app dir on
`destroy`, never read back by the gem itself.

## Template substitution

`{{VAR}}` placeholders inside any template are replaced from:

1. **Git** (computed locally): `{{GIT_BRANCH}}`, `{{GIT_BRANCH_UNDERSCORE}}`
2. **`.yaml`**: every non-behavioral key uppercased -- `{{SERVER}}`, `{{DOMAIN}}`, etc.
3. **Server probe**: `{{PORT}}` -- reused from existing `.env`, or
   first free port in `3010..3990` step 10 (via `ss -tln`)
4. **Derived**: `{{DIR}}`, `{{RUBY}}`, `{{RUBY_DIR}}`
5. **The rendered `.env`** itself: every `KEY=VAL` line becomes a placeholder
   you can use in `caddy.conf` / `systemd.service` (e.g. `{{DOMAIN}}`)

Order: render `.env` first, parse it, then render the other templates with
the resulting env hash merged in.

Behavioral keys (`service_user`, `remote_base`, `service_prefix`,
`job_service_prefix`, `smoke_command`) are excluded from the placeholder
namespace - they configure the engine, not the templates.

## Deploy flow

```
 1. read config/deploy/.yaml (merged: engine defaults < plugin defaults < user .yaml)
 2. pick template:  master|main -> .env, anything else -> .env.staging
 3. render .env -> derive <app> from DOMAIN (falls back to .yaml domain)
 4. before_local.sh   (LOCAL, if present; non-zero exit -> abort)
 5. ensure remote dirs (service_user-owned)
 6. allocate / reuse PORT
 7. rsync code to new-release/
 8. symlink tmp, log, .env into new-release/
 9. upload rendered .env / systemd.service / caddy.config
10. bundle install (vendor/bundle, without development+test)
11. smoke (config.smoke_command; abort + cleanup on failure)
12. atomic swap:  rm old-release; mv release old-release; mv new-release release
13. install symlinks under /etc/systemd/system and /etc/caddy/sites
14. systemctl daemon-reload + restart web + reload caddy
15. (if job.service present) restart <job-prefix>-<app>
16. after_server.sh   (SERVER, if present; non-zero exit -> warn, do not roll back)
17. write <app_dir>/lux-deploy.yaml (manifest)
```

On any failure between step 7 and step 12, `release/` is untouched.

## Notes

* `lux-deploy destroy` prompts `type '<domain>' to confirm` unless `--yes`.
* `lux-deploy redeploy` always allocates a fresh PORT.
* Concurrent deploys for the same app are not locked. Don't.
