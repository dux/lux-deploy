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
bundle exec lux-deploy app:init      # copy starter templates into ./config/deploy/
$EDITOR config/deploy/.yaml          # set server: and domain:
$EDITOR config/deploy/systemd.service # set your ExecStart
bundle exec lux-deploy prepare:caddy # install + wire the reverse proxy (one-time, per host)
bundle exec lux-deploy doctor        # check the host
bundle exec lux-deploy up            # ship it
```

## Host preparation

`prepare:*` bootstraps the reverse proxy on a fresh host - one command,
run once per server (it is idempotent, so re-running is safe):

```sh
lux-deploy prepare:caddy     # install Caddy, create /etc/caddy/sites, wire the import, enable
lux-deploy prepare:nginx     # install nginx, create sites-enabled, wire the include, enable
lux-deploy prepare:mise      # install mise for the service user, activate it in the login shell
lux-deploy prepare:bun       # install Bun for the service user
lux-deploy caddy:log:prepare # install Bun + the host-wide access-log -> SQLite importer
```

The proxy tasks target Debian/Ubuntu (apt) and run as root over SSH. This is
the one gap `doctor` does not close on its own: `doctor` *checks* that the
proxy and mise are installed and wired, but never installs them for you -
`prepare:*` does. `prepare:mise` installs mise under the service user and
wires `mise activate bash` into `~/.profile`, so the login shell every remote
deploy step uses (`sudo -iu <user> bash -lc`) resolves `ruby`/`bundle`.

The deploy flow itself is **Caddy-fronted**: `up` renders a `caddy.config`
and links it into `/etc/caddy/sites/<app>.caddy`. `prepare:nginx` installs
and wires nginx as host groundwork, but the deploy does not yet emit nginx
site files - use it when you are setting up nginx for other purposes on the
box, or as the basis for a custom proxy setup.

## Configuration: `config/deploy/.yaml`

Required:

```yaml
server:        srv.example.com
domain:        example.com
```

Optional (defaults shown):

```yaml
service_user:       deployer                # unix user that owns the app dir
remote_base:        /home/deployer/apps     # ~/<remote_base>/<app>/
service_prefix:     web                     # systemd units: <prefix>-<app>[-<svc>]
```

Any other key becomes an UPPERCASE `{{KEY}}` placeholder available to every
template under `config/deploy/`.

### Post-deploy verification

Put smoke checks in `config/deploy/remote_after.sh`. It runs on the
server inside `release/` after the atomic swap and service reload, with
the rendered `.env` already sourced. If the file exists and exits
non-zero, `lux-deploy up` exits failed. The new release is already live,
so lux-deploy does not automatically roll it back.

Use any command in any language: a ruby boot-eval, an rspec invocation,
a shell script, a python test, a `curl` against the deployed URL, etc.
You can re-run it directly with `lux-deploy on:remote:after`.

### Lifecycle hooks: `local_before` / `remote_before` / `remote_after` / `local_after`

Optional scripts in `config/deploy/`. The name is the contract:
`local_*` runs on your machine, `remote_*` runs on the production box;
`*_before` runs before the swap, `*_after` runs after it.
Every hook slot is announced on every deploy - missing hooks log
`==> run config/deploy/<name> (not defined, skipping)` so absence is
visible, not silent. `app:init` ships scaffolds; `doctor` reports which
are present.

| file | where | when | failure |
| --- | --- | --- | --- |
| `local_before.sh`  | local repo root        | before any remote work (right after context build)                          | abort - no remote state changed |
| `remote_before.sh` | server `new-release/`  | after rsync + .env upload, `.env` already sourced; before swap              | abort - `new-release/` kept, `release/` untouched |
| `remote_after.sh`  | server `release/`      | after atomic swap + service reload, `.env` sourced                          | fail - new release is already live |
| `local_after.sh`   | local repo root        | after the manifest is written and the deploy is live                        | warn - new release is already live |

`remote_before.sh` is where you do the language-specific work -
`bundle install`, `npm ci`, `go build`, migrations, asset compile. The
engine does not run any of those itself; the `app:init` scaffold ships a
working Ruby/Bundler default that you can edit or replace. `local_after.sh`
is the natural place to clean up whatever `local_before.sh` built (e.g.
`vendor/cache`) or to fire a post-deploy notification.

The `remote_*` hooks live in the repo and are rsync'd to the server with
everything else. The server has no special awareness of these files -
lux-deploy itself runs the named hook on the named side. The `local_*`
hooks ride along to the server too but are never executed there.

> Renamed in 0.2.0 (was `before_local` / `before_server` / `after_server`).
> `up` aborts with a `mv` hint if it finds an old-named hook.

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
    remote_base:        '/home/deployer/lux-apps'
  }
)
```

Precedence: user `.yaml` > plugin `defaults` > engine defaults.

## Commands

| command                | purpose |
| ---------------------- | ------- |
| `lux-deploy up`        | deploy current branch |
| `lux-deploy redeploy`  | destroy + deploy (fresh PORTs) |
| `lux-deploy destroy`   | stop service, unlink caddy/systemd, remove `~/<remote_base>/<app>` |
| `lux-deploy doctor`    | check + auto-fix host (deployer user, dirs, caddy, ruby, bundler) |
| `lux-deploy app:init`  | copy bundled templates into `./config/deploy/` |
| `lux-deploy prepare:caddy` | install + configure Caddy on the host (sites dir, import, enable) |
| `lux-deploy prepare:nginx` | install + configure nginx on the host (sites-enabled, enable) |
| `lux-deploy prepare:mise` | install mise for the service user + activate it in the login shell |
| `lux-deploy prepare:bun` | install Bun for the service user |
| `lux-deploy caddy:log:prepare` | install Bun + the host-wide access-log -> SQLite importer |
| `lux-deploy caddy:log:status` | importer service status + this app's SQLite stats |
| `lux-deploy on:local:before`  | run `config/deploy/local_before.sh` locally |
| `lux-deploy on:remote:before` | run `config/deploy/remote_before.sh` on `new-release/` |
| `lux-deploy on:remote:after`  | run `config/deploy/remote_after.sh` on `release/` |
| `lux-deploy on:local:after`   | run `config/deploy/local_after.sh` locally |
| `lux-deploy server:ssh`     | open a shell on the release dir |
| `lux-deploy server:log`     | tail the systemd journal |
| `lux-deploy server:errors`  | tail -f the app error log |
| `lux-deploy server:restart` | restart the web service |
| `lux-deploy server:status`  | systemd status |

Database tasks live in `lux db:*` from lux-fw's `db` plugin and run against the local app DB.

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
  systemd.service        # the web service (caddy-fronted)
  <name>.service         # optional: any extra service (job runner, grpc, ...)
```

The two required keys are `server` and `domain`. Any additional key
becomes an UPPERCASE `{{KEY}}` placeholder available to every template
(e.g. add `cdn: cdn.example.com` and use `{{CDN}}` in caddy.conf).

### Multiple services & ports

A **service is a file**: `systemd.service` is the web service (the one
caddy proxies to); every other `config/deploy/<name>.service` becomes a
second systemd unit `<service_prefix>-<app>-<name>`, enabled and restarted
on each deploy. No list to maintain - drop a file, it deploys; remove it
and `destroy` no longer knows about it (clean the unit up by hand once).

**Disable without deleting**: prefix any file with `!` and lux-deploy
ignores it everywhere - `!job.service` stops deploying as a service, and the
`!`-file is never rsynced. The convention is global: any `!`-prefixed file
in the repo (e.g. `!scratch.rb`) is excluded from the deploy. A `!`-disabled
service is *not* torn down automatically - stop its unit on the box once
(`systemctl disable --now <service_prefix>-<app>-<name>`).

**Ports are magic**: any token matching `PORT*` is auto-allocated, persisted
into the remote `.env` (0600), and reused on every later deploy. The set is
the union of `PORT*` keys in `.env`/`.env.staging` and `{{PORT*}}`
placeholders in any template. So a worker that needs its own port just
references `{{PORT_JOB}}` in its unit (and/or declares `PORT_JOB=` in
`.env`); the web service keeps its single `{{PORT}}`. The host is only
probed for free ports when something new must be allocated - reuse never
touches the network.

```
# config/deploy/.env            after first deploy (persisted on server):
PORT=                           PORT=3010
PORT_JOB=                       PORT_JOB=3020
```

### Polyglot

Nothing here is Ruby-specific. `{{RUBY}}`/`{{RUBY_DIR}}` (and the ruby
probe) are only resolved when a template actually references them - a Go or
Python service whose unit runs a built binary (`ExecStart={{DIR}}/release/app`)
never triggers the probe, and `doctor` skips the ruby/bundler host checks.
Build your app however you like in `remote_before.sh` (`go build`,
`pip install`, `npm ci`, `bundle install`); post-deploy verification goes
in `remote_after.sh` and fails the command by exiting non-zero.

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
  log/                     # access logs (service_user:caddy 2775); only if logging is on
    <app>.jsonl            # caddy JSON access log (rolled by caddy)
    caddy.sqlite           # imported by the host-wide lux-caddylog service
  .env                     # rendered, PORT* live here (0600)
  systemd.service          # rendered web unit; linked to /etc/systemd/system/<prefix>-<app>.service
  systemd.<name>.service   # rendered extra unit; linked to /etc/systemd/system/<prefix>-<app>-<name>.service
  caddy.config             # rendered; linked into /etc/caddy/sites/<app>.caddy
  lux-deploy.yaml          # post-deploy manifest, mode 0644 (see below)
```

`<app>` is the first comma-separated value of `DOMAIN` from the rendered
`.env` (falls back to `.yaml`'s `domain:`; wildcards stripped: `*.foo` -> `foo`).

## Access logging (Caddy -> SQLite)

Optional. The `app:init` `caddy.conf` emits a JSON access log to
`<app_dir>/log/<app>.jsonl` (rolled by caddy: 1GiB, 48 files, 168h). A single
host-wide importer service (`lux-caddylog`, Bun) tails every site's JSONL and
batch-inserts into that site's `caddy.sqlite` - crash-safe (rows + offset
committed in one transaction; `event_id = sha256(line)` dedups on replay),
rotation-aware, and pruned to 30 days.

```
Caddy -> <app_dir>/log/<app>.jsonl --(lux-caddylog)--> <app_dir>/log/caddy.sqlite
```

Behind Cloudflare, the importer reads the real visitor IP (`CF-Connecting-IP`)
and `country` (`CF-IPCountry`) from request headers - the connection's
`remote_ip` is the Cloudflare edge. `raw_json` keeps the full entry; common
fields (`ts, remote_ip, country, method, host, uri, status, duration, size,
user_agent, referer`) are extracted into columns.

```sh
lux-deploy caddy:log:prepare   # one-time per host: Bun + importer + enable lux-caddylog
lux-deploy up                  # caddy starts logging; importer picks the site up
lux-deploy caddy:log:status    # importer state + row count / ts span for this app
```

Existing apps are untouched until they re-`app:init` (or add the `log {}` block
to their `caddy.conf`); the importer only watches sites that produce a JSONL.

## Manifest: `lux-deploy.yaml`

Every successful `up` writes a `lux-deploy.yaml` next to `.env` on the
remote. It is a self-describing snapshot of what is wired up: every
service, its unit name and ExecStart, caddy paths, allocated ports, git
commit, non-secret env values, and a few ready-to-paste shell helpers
(`systemctl restart ...`, `journalctl -u ...`, `systemctl reload caddy`).

It is mode 0644 and never contains secrets: any key matching
`SECRET / PASSWORD / TOKEN / KEY / DB_URL / DATABASE_URL / CREDENTIAL`
keeps its name but its value is replaced with `<redacted>`.

Intended consumers: humans, LLMs, monitoring scripts, future lux-deploy
commands. Regenerated on every deploy, removed with the app dir on
`destroy`, never read back by the gem itself.

## Template substitution

Every template (`.env`, `.env.staging`, `caddy.conf`, and each
`*.service` unit) is rendered in a single pass with the same vars:

1. **Git** (computed locally): `{{GIT_BRANCH}}`, `{{GIT_BRANCH_UNDERSCORE}}`
2. **App** (derived from `domain:`): `{{APP}}`, `{{APP_UNDERSCORE}}`,
   `{{HASH}}` (`h` + first 6 SHA-256 hex chars of the main domain),
   `{{TAG}}` (`s` + first 5 SHA-256 hex chars of the main domain)
3. **`.yaml`**: every non-behavioral key uppercased -- `{{SERVER}}`, `{{DOMAIN}}`, etc.
4. **Ports**: `{{PORT}}` and any `{{PORT_*}}` -- reused from the existing
   `.env`, or first free ports in `3010..3990` step 10 (via `ss -tln`)
5. **Derived**: `{{DIR}}`, plus `{{RUBY}}`/`{{RUBY_DIR}}` only when a
   template references them

`.env` does **not** feed back into the placeholder namespace. It is a
runtime-only file -- rendered once, uploaded verbatim, and read by the
running app at boot. `caddy.conf` / `systemd.service` cannot reference
keys defined inside `.env`; if you need a value in both places put it
in `.yaml` (so it becomes `{{KEY}}`) and the app's `.env` can reference
the same `{{KEY}}` if you want it duplicated there.

Behavioral keys (`service_user`, `remote_base`, `service_prefix`) are
excluded from the placeholder namespace - they configure the engine, not
the templates. `PORT*` are engine-provided, so units/caddy may reference
`{{PORT_*}}` without declaring them in `.yaml`.

## Deploy flow

```
 1. read config/deploy/.yaml (merged: engine defaults < plugin defaults < user .yaml)
 2. derive <app> from yaml `domain:` (first comma-split, strip leading "*.")
 3. pick .env template: master|main -> .env, anything else -> .env.staging
 4. local_before.sh   (LOCAL, if present; non-zero exit -> abort)
 5. ensure remote dirs (service_user-owned)
 6. wipe stale new-release/ (from a prior failed deploy, if any)
 7. allocate / reuse every PORT*
 8. render templates (.env, caddy.conf, each *.service unit)

 9. rsync code to new-release/
10. symlink tmp, log, .env into new-release/
11. upload rendered .env / *.service / caddy.config
12. remote_before.sh  (SERVER, in new-release/, .env sourced; abort on failure -- new-release/ kept for inspection)
                       This is where your app installs gems / npm / go build / migrations / asset compile.
                       lux-deploy ships nothing language-specific past this point.
13. atomic swap:  rm old-release; mv release old-release; mv new-release release
14. install symlinks under /etc/systemd/system and /etc/caddy/sites
15. systemctl daemon-reload + enable/restart every service + reload caddy
16. remote_after.sh   (SERVER, in release/, .env sourced; non-zero exit -> fail, no auto rollback)
17. write <app_dir>/lux-deploy.yaml (manifest)
18. local_after.sh    (LOCAL, if present; non-zero exit -> warn, deploy is already live)
```

Every lifecycle hook step is always announced - if the file is missing
the line reads e.g. `==> run config/deploy/local_before.sh (not defined, skipping)`
so absence is visible, not silent.

On any failure between step 9 and step 12, `release/` is untouched and
`new-release/` is left in place on the server (path printed in the
error). `lux-deploy server:ssh` to inspect; the next `lux-deploy up`
wipes `new-release/` at step 6. Run `lux-deploy on:remote:before` to
re-run the server-side pre-swap hook against the current `new-release/`.
If `remote_after.sh` fails at step 16, the command fails but the new
release is already live.

## Notes

* `lux-deploy destroy` prompts `type '<domain>' to confirm` unless `--yes`.
* `lux-deploy redeploy` wipes the app dir, so all `PORT*` are re-allocated fresh.
* Concurrent deploys for the same app are not locked. Don't.
