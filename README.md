# lux-deploy

Stupid-simple deploy via SSH + rsync.
No Docker. No registry. No JSON.

Caddy + systemd + atomic-release deploys.
The primary configuration lives in `config/deploy/.yaml`, with an optional non-secret `config/deploy/src` override for the local deploy artifact.
No adapter classes or plugins need to be registered.
Host defaults are baked into the gem, and app-specific settings go in the deploy configuration.

**A git branch is a deploy.** `main` serves your `domain:`; every other branch gets its own directory, its own systemd units, its own ports and its own hostname, under the same app. Nothing a branch does can touch production.

```
/home/deployer/apps/example.com/main/     example.com, www.example.com
/home/deployer/apps/example.com/topic/    topic.example.com
```

A file is the contract.
Drop `job.service` in `config/deploy/` and it deploys as a second unit.
Drop `remote_before.sh` and it becomes your build step.
Prefix any file with `!` and it disappears from the deploy.
Nothing to register, nothing to wire up - and when you do want to wire something up by hand, the file you would edit is the same one the engine reads.

## The port contract

lux-deploy allocates a port, writes it into the app's `.env` as `PORT`, and points Caddy at it.
Your app listens on `$PORT`.
That is the entire interface between the engine and your code - no agent on the box, no HTTP semantics, nothing language-specific.

Ports are allocated once and reused on every later deploy, so `PORT` is stable for the life of the app.
Everything else (TLS, the reverse proxy, the systemd unit, access logs) is the engine's job, and every piece of it is a template you can edit.

The contract is checked, not assumed.
After restarting the units, `up` waits up to `boot_timeout` seconds (default 30) for something to be listening on every allocated `PORT*`, then asserts every unit is `active`.
Only then does it reload Caddy and run `remote_after.sh`.
A release that does not boot fails the deploy with the journal printed, instead of reporting `done` over a crash-looping process.

```yaml
health:        true    # false skips the wait entirely
boot_timeout:  30      # seconds
health_path:   /up     # optional: also require an HTTP 2xx on 127.0.0.1:$PORT/up
```

And if that is not the right check, `config/deploy/health.sh` **replaces** it - same shape as the other hooks (server, in `release/`, `.env` sourced), non-zero exit means the release is not serving.
`app:init` ships it as `!health.sh` with the built-in check written out in bash; rename it to `health.sh` to take over.

> This is a correctness gate, not zero-downtime. `PORT` is stable across deploys, so a restart is a gap on the same upstream rather than a switch to a new one - the gate tells you the new process came up, it does not hide the restart.
> The shipped `caddy.conf` sets `lb_try_duration 10s`, which holds requests open through that gap instead of returning 502.

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
bundle exec lux-deploy status        # what is live
```

## Host preparation

`prepare:*` bootstraps the reverse proxy on a fresh host - one command, run once per server (it is idempotent, so re-running is safe):

```sh
lux-deploy prepare:caddy     # install Caddy, create /etc/caddy/sites, wire the import, enable
lux-deploy prepare:mise      # install mise for the service user, activate it in the login shell
lux-deploy prepare:bun       # install Bun for the service user
lux-deploy caddy:log:prepare # install Bun + the host-wide access-log -> SQLite importer
```

These target Debian/Ubuntu (apt) and run as root over SSH.
This is the one gap `doctor` does not close on its own: `doctor` *checks* that Caddy and mise are installed and wired, but never installs them for you - `prepare:*` does.
`prepare:mise` installs mise under the service user and wires `mise activate bash` into `~/.profile`, so the login shell every remote deploy step uses (`sudo -iu <user> bash -lc`) resolves `ruby`/`bundle`.

### Why Caddy, and only Caddy

`up` renders a `caddy.config` and links it into `/etc/caddy/sites/<app>.caddy`.
There is no nginx path, and that is deliberate rather than unfinished: three things the gem does for free are Caddy doing the work.

* **TLS.** Caddy handles ACME itself - issuance, renewal, stapling. The whole TLS story here is `{{DOMAIN}} { ... }`. nginx would mean certbot, a renewal timer, a reload hook and per-site certificate paths.
* **Reload safety.** Caddy validates before an atomic swap, so a broken site file fails the reload and leaves the running config alone. A bad `nginx -t` followed by a reload takes down every site on the box, not just yours - a bad blast radius for a per-app deploy tool.
* **Access logs.** The `caddy:log:*` importer reads Caddy's native JSON log, and `roll_size`/`roll_keep` are Caddy directives. nginx has no JSON log; you would hand-build a `log_format`, add logrotate, and rewrite the importer.

If you want a different proxy, replace all three - which is a different gem, not a config flag.
The same reasoning applies to systemd and Debian: see the note at the top of `lib/lux_deploy.rb`.

## Configuration: `config/deploy/.yaml`

Required:

```yaml
server:        srv.example.com
domain:        example.com
```

Optional (defaults shown):

```yaml
service_user:       deployer                # unix user that owns the app dir
remote_base:        /home/deployer/apps     # <remote_base>/<domain>/<branch>/
service_prefix:     web                     # systemd units: <prefix>-<app>[-<svc>]
src:                ./                      # local directory copied by rsync
on_fail:            keep                    # keep | rollback, when a post-swap step fails
health:             true                    # false disables the port-contract wait
boot_timeout:       30                      # seconds to wait for the app to bind PORT
health_path:                                # e.g. /up - adds an HTTP probe on top
branch_domain:      '{{GIT_BRANCH_SLUG}}.{{APP_DOMAIN}}'   # hostname for a non-main branch
```

### Branches

Every deploy is a git branch. `master`/`main` is the production one; everything else is a separate deploy of the same app.

| | `main` | branch `topic` |
| --- | --- | --- |
| serves (`{{DOMAIN}}`) | `example.com, www.example.com` | `topic.example.com` |
| directory | `<remote_base>/example.com/main/` | `<remote_base>/example.com/topic/` |
| units | `web-example.com-main` | `web-example.com-topic` |
| caddy site | `example.com-main.caddy` | `example.com-topic.caddy` |
| env template | `.env.main` | `.env.default` |
| ports, `.env`, `.env.local`, lock, rollback | its own | its own |

Branch names are DNS-slugged (`feature/Login-42` → `feature-login-42`), so they are safe in a hostname, a unit name and a directory name.

`branch_domain:` sets the hostname pattern - it renders with `{{GIT_BRANCH}}`, `{{GIT_BRANCH_UNDERSCORE}}`, `{{GIT_BRANCH_SLUG}}` and `{{APP_DOMAIN}}` (the first entry of `domain:`).
Set it to `'{{GIT_BRANCH_SLUG}}.staging.{{APP_DOMAIN}}'` if you would rather cover every branch with one `*.staging.example.com` wildcard cert than let Caddy issue a certificate per branch host.

`caddy.conf` and the unit templates need no branch awareness of their own: `{{DOMAIN}}` is already the right host for whichever branch is deploying.
`{{HASH}}` and `{{TAG}}` derive from it too, so the caddy snippet name differs per branch rather than colliding.

Tear one down with `lux-deploy destroy` from that branch; the parent `<domain>/` directory is removed once its last branch is gone.

For a locally built deploy artifact, put its path in `config/deploy/src`.
This non-secret file takes precedence over `.yaml` `src` and can be committed with the deploy configuration.
For example, a Lux app packed with `lux pack` uses `./tmp/app-packed`.

Any other key becomes an UPPERCASE `{{KEY}}` placeholder available to every template under `config/deploy/`.

### Ruby extension point: `config/deploy/init.rb`

If `config/deploy/init.rb` exists it is `load`ed before any task runs.
Use it to define extra Hammer tasks or set `LuxDeploy.set_defaults` without writing your own Hammerfile.

## Environment

`config/deploy/.env` is a template.
It is rendered on every deploy and uploaded to `<app_dir>/.env` (0600), which the systemd unit reads via `EnvironmentFile=`.
Because it is re-rendered every time, editing `<app_dir>/.env` on the server does not survive the next deploy.

`<app_dir>/.env.local` does.
It is server-only, never rsynced, never rendered, and merged *over* the rendered `.env` on every deploy.
That is where real secrets belong - the repo template can then hold only the shape of the env.

```sh
lux-deploy env:list          # effective server env, secrets redacted, * marks .env.local keys
lux-deploy env:get SECRET    # one value, unredacted, for scripting
lux-deploy env:set SECRET=…  # write to .env.local, fold into the live .env, restart
lux-deploy env:edit          # $EDITOR on .env.local, then the same
```

The manual equivalent is `lux-deploy server:ssh` and editing `.env.local` yourself; the commands are sugar over exactly that file.
`PORT*` keys in `.env.local` are ignored with a warning - ports are engine-allocated, and pinning one there would only desync Caddy from the unit.

### Post-deploy verification

Put smoke checks in `config/deploy/remote_after.sh`.
It runs on the server inside `release/` after the atomic swap and service reload, with the rendered `.env` already sourced.
If the file exists and exits non-zero, `lux-deploy up` fails.

By default the new release stays live and you decide what to do (`on_fail: keep`).
Set `on_fail: rollback` in `.yaml` and any post-swap failure - the health gate or `remote_after.sh` - restores the previous release automatically.

Use any command in any language: a ruby boot-eval, an rspec invocation, a shell script, a python test, a `curl` against the deployed URL, etc.
You can re-run it directly with `lux-deploy on:remote:after`.

### Lifecycle hooks: `local_before` / `remote_before` / `remote_after` / `local_after`

Optional scripts in `config/deploy/`.
The name is the contract: `local_*` runs on your machine, `remote_*` runs on the production box; `*_before` runs before the swap, `*_after` runs after it.
Every hook slot is announced on every deploy - missing hooks log `==> run config/deploy/<name> (not defined, skipping)` so absence is visible, not silent.
`app:init` ships scaffolds; `doctor` reports which are present.

| file | where | when | failure |
| --- | --- | --- | --- |
| `local_before.sh`  | local repo root        | before any remote work (right after context build)                          | abort - no remote state changed |
| `remote_before.sh` | server `new-release/`  | after rsync + .env upload, `.env` already sourced; before swap              | abort - `new-release/` kept, `release/` untouched |
| `health.sh`        | server `release/`      | after the restart, replacing the built-in port wait; before caddy is reloaded | fail; rolls back only with `on_fail: rollback` |
| `remote_after.sh`  | server `release/`      | after the health gate + caddy reload, `.env` sourced                        | fail; rolls back only with `on_fail: rollback` |
| `local_after.sh`   | local repo root        | after the manifest is written and the deploy is live                        | warn - new release is already live |

`remote_before.sh` is where you do the language-specific work - `bundle install`, `npm ci`, `go build`, migrations, asset compile.
The engine does not run any of those itself; the `app:init` scaffold ships a working Ruby/Bundler default that you can edit or replace.
`local_after.sh` is the natural place to clean up whatever `local_before.sh` built (e.g. `vendor/cache`) or to fire a post-deploy notification.

Local hooks get the deploy context in their environment: `LUX_DEPLOY_APP`, `LUX_DEPLOY_DOMAIN`, `LUX_DEPLOY_HOST`, `LUX_DEPLOY_BRANCH`, `LUX_DEPLOY_DIR`, `LUX_DEPLOY_PORT`.

The `remote_*` hooks live in the repo and are rsync'd to the server with everything else.
The server has no special awareness of these files - lux-deploy itself runs the named hook on the named side.
The `local_*` hooks ride along to the server too but are never executed there.

> Renamed in 0.2.0 (was `before_local` / `before_server` / `after_server`).
> `up` aborts with a `mv` hint if it finds an old-named hook.

### Wrapping lux-deploy from another gem / Hammerfile

A wrapping plugin (e.g. lux-fw's `plugins/deploy/`) can seed defaults that sit *under* the user's `.yaml`:

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

## Rollback

Every deploy keeps the release it replaced in `old-release/`, together with the rendered `.env`, unit files and caddy config that shipped with it (in `<release>/.lux-deploy/`).
`lux-deploy rollback` puts all of that back.

```sh
lux-deploy rollback              # confirm, swap, restore artifacts, restart
lux-deploy rollback --yes        # no prompt
lux-deploy rollback --dry-run    # print the commands, which is also how you do it by hand
```

It prints the commit it is coming from and the one it is going to, both read from the manifests on the box.
The swap is symmetric, so running `rollback` twice returns you to where you started.
Depth is one release - `up` keeps exactly one previous release, by design.

Units are resolved from the restored release's own manifest, not from your checkout: a service added since that release is not restarted, and one dropped since then is stopped and unlinked.

## Status

```sh
lux-deploy status      # this app: commit, units, ports, rollback availability
lux-deploy host:apps   # every app on the host, from their manifests
```

`status` reads `<app_dir>/lux-deploy.yaml`, then asks systemd which units are active, checks whether anything is listening on each allocated port, resolves every `/etc/caddy/sites` and `/etc/systemd/system` symlink, and confirms that what Caddy proxies to is what `.env` says `PORT` is.
`host:apps` reads every `<remote_base>/*/lux-deploy.yaml` in one round trip.

## Commands

| command                | purpose |
| ---------------------- | ------- |
| `lux-deploy up`        | deploy current branch |
| `lux-deploy rollback`  | restore the previous release |
| `lux-deploy migrate`   | move a pre-0.3 flat app dir into the `<domain>/<branch>` layout |
| `lux-deploy status`    | what is live: commit, units, ports, rollback availability |
| `lux-deploy redeploy`  | destroy + deploy (fresh PORTs) |
| `lux-deploy destroy`   | stop this branch's services, unlink caddy/systemd, remove its dir |
| `lux-deploy doctor`    | check + auto-fix host (deployer user, dirs, caddy, ruby, bundler) |
| `lux-deploy app:init`  | copy bundled templates into `./config/deploy/` |
| `lux-deploy env:list`  | effective server env, secrets redacted |
| `lux-deploy env:get KEY` | one value, unredacted |
| `lux-deploy env:set KEY=VAL` | write to the server-only `.env.local`, restart |
| `lux-deploy env:edit`  | `$EDITOR` on the server-only `.env.local`, restart |
| `lux-deploy host:apps` | list every app deployed on the host |
| `lux-deploy log`       | list `release/log/`, or dump one with `--log <name> --lines 200` |
| `lux-deploy prepare:caddy` | install + configure Caddy on the host (sites dir, import, enable) |
| `lux-deploy prepare:mise` | install mise for the service user + activate it in the login shell |
| `lux-deploy prepare:bun` | install Bun for the service user |
| `lux-deploy caddy:doctor` | check the caddy install + table every site file on the host |
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
* `--yes`         -- skip the `destroy` / `rollback` confirmation
* `--force`       -- `up` breaks an existing deploy lock
* `--no-fix`      -- `doctor` reports only, no auto-fix

## Project layout (in your app)

```
config/deploy/
  .yaml                  # server: + domain: + any overrides + custom {{KEY}}s
  src                    # optional local rsync source; overrides .yaml src
  init.rb                # optional ruby loaded before any task
  health.sh              # optional: replaces the built-in port-contract wait
  .env.main              # env for master/main
  .env.default           # env for every other branch
  .env.<branch>          # optional, wins for that one branch
  caddy.conf             # caddy site file
  systemd.service        # the web service (caddy-fronted)
  <name>.service         # optional: any extra service (job runner, grpc, ...)
```

The two required keys are `server` and `domain`.
Any additional key becomes an UPPERCASE `{{KEY}}` placeholder available to every template (e.g. add `cdn: cdn.example.com` and use `{{CDN}}` in caddy.conf).

### Multiple services & ports

A **service is a file**: `systemd.service` is the web service (the one caddy proxies to); every other `config/deploy/<name>.service` becomes a second systemd unit `<service_prefix>-<app>-<name>`, enabled and restarted on each deploy.
No list to maintain - drop a file, it deploys.
Remove it and the next `destroy` still cleans it up, because teardown reads the manifest on the box rather than your checkout.

**Disable without deleting**: prefix any file with `!` and lux-deploy ignores it everywhere - `!job.service` stops deploying as a service, and the `!`-file is never rsynced.
The convention is global: any `!`-prefixed file in the repo (e.g. `!scratch.rb`) is excluded from the deploy.
A `!`-disabled service is *not* torn down automatically - stop its unit on the box once (`systemctl disable --now <service_prefix>-<app>-<name>`).

**Ports are magic**: any token matching `PORT*` is auto-allocated, persisted into the remote `.env` (0600), and reused on every later deploy.
The set is the union of `PORT*` keys in the branch's env template and `{{PORT*}}` placeholders in any template.
So a worker that needs its own port just references `{{PORT_JOB}}` in its unit (and/or declares `PORT_JOB=` in the branch's env template); the web service keeps its single `{{PORT}}`.
The host is only probed when something new must be allocated - reuse never touches the network.
When it does probe, it excludes both the ports currently listening (`ss -tln`) and every `PORT*` claimed in any app's `.env` on the host, so an app that happens to be stopped does not lose its port to the next deploy.

```
# config/deploy/.env.main       after first deploy (persisted on server):
PORT=                           PORT=3010
PORT_JOB=                       PORT_JOB=3020
```

### Polyglot

Nothing here is Ruby-specific.
`{{RUBY}}`/`{{RUBY_DIR}}` (and the ruby probe) are only resolved when a template actually references them - a Go or Python service whose unit runs a built binary (`ExecStart={{DIR}}/release/app`) never triggers the probe, and `doctor` skips the ruby/bundler host checks.
Build your app however you like in `remote_before.sh` (`go build`, `pip install`, `npm ci`, `bundle install`); post-deploy verification goes in `remote_after.sh` and fails the command by exiting non-zero.

## Server layout

`<app>` below is `<domain>-<branch>` - the flat name used for units, the caddy file and the access log. The directory itself nests one level deeper, so every branch of an app sits under one parent.

```
<remote_base>/<domain>/           # e.g. apps/example.com/ - holds every branch
  <branch>/                       # e.g. main/, topic/ - one complete deploy
    release/                 # current code + bundle
      tmp -> ../shared/tmp
      log -> ../shared/log
      .env -> ../.env
      .lux-deploy/           # the rendered artifacts this release shipped with
    old-release/             # previous release, kept one cycle (what `rollback` restores)
    shared/
      tmp/                   # survives release swap
      log/                   # survives release swap
    log/                     # access logs (service_user:caddy 2775); only if logging is on
      <app>.jsonl            # caddy JSON access log (rolled by caddy)
      caddy.sqlite           # imported by the host-wide lux-caddylog service
    .env                     # rendered, PORT* live here (0600)
    .env.local               # server-only overlay, merged over .env (0600)
    .deploy.lock             # present only while a deploy is running
    systemd.service          # rendered web unit; linked to /etc/systemd/system/<prefix>-<app>.service
    systemd.<name>.service   # rendered extra unit; linked to /etc/systemd/system/<prefix>-<app>-<name>.service
    caddy.config             # rendered; linked into /etc/caddy/sites/<app>.caddy
    lux-deploy.yaml          # post-deploy manifest, mode 0644 (see below)
```

Everything is a symlink into that tree, so the install is inspectable with `ls -l`:

```
/etc/caddy/sites/example.com-main.caddy   -> <remote_base>/example.com/main/caddy.config
/etc/systemd/system/web-example.com-main.service -> <remote_base>/example.com/main/systemd.service
```

`lux-deploy caddy:doctor` walks exactly that: whether caddy is installed, running and importing `/etc/caddy/sites/*.caddy`, then a table of every site file with the domains it declares, the upstream it proxies to, and where its symlink resolves (a dangling one shows as `BROKEN` instead of a silent 502).

`<app>` is the first comma-separated value of `domain:` from `.yaml` (wildcards stripped: `*.foo` -> `foo`).

## Access logging (Caddy -> SQLite)

Optional.
The `app:init` `caddy.conf` emits a JSON access log to `<app_dir>/log/<app>.jsonl` (rolled by caddy: 1GiB, 48 files, 168h).
A single host-wide importer service (`lux-caddylog`, Bun) tails every site's JSONL and batch-inserts into that site's `caddy.sqlite` - crash-safe (rows + offset committed in one transaction; `event_id = sha256(line)` dedups on replay), rotation-aware, and pruned to 30 days.

```
Caddy -> <app_dir>/log/<app>.jsonl --(lux-caddylog)--> <app_dir>/log/caddy.sqlite
```

Behind Cloudflare, the importer reads the real visitor IP (`CF-Connecting-IP`) and `country` (`CF-IPCountry`) from request headers - the connection's `remote_ip` is the Cloudflare edge.
`raw_json` keeps the full entry; common fields (`ts, remote_ip, country, method, host, uri, status, duration, size, user_agent, referer`) are extracted into columns.

```sh
lux-deploy caddy:log:prepare   # one-time per host: Bun + importer + enable lux-caddylog
lux-deploy up                  # caddy starts logging; importer picks the site up
lux-deploy caddy:log:status    # importer state + row count / ts span for this app
```

Existing apps are untouched until they re-`app:init` (or add the `log {}` block to their `caddy.conf`); the importer only watches sites that produce a JSONL.

## Manifest: `lux-deploy.yaml`

Every successful `up` writes a `lux-deploy.yaml` next to `.env` on the remote, and a copy into `release/.lux-deploy/`.
It is a self-describing snapshot of what is wired up: every service, its unit name and ExecStart, caddy paths, allocated ports, git commit, non-secret env values, and a few ready-to-paste shell helpers (`systemctl restart ...`, `journalctl -u ...`, `systemctl reload caddy`).

It is mode 0644 and never contains secrets.
Any key whose name contains `SECRET / PASSWORD / TOKEN / KEY / DB_MAIN / DB_URL / DATABASE_URL / CREDENTIAL` keeps its name but its value is replaced with `<redacted>`, and as a backstop any value carrying URL-embedded credentials (`scheme://user:pass@host`) is redacted regardless of key name.

Consumers: humans, LLMs, monitoring scripts, and lux-deploy itself - `status`, `host:apps`, `rollback` and `destroy` all read it, so what the engine acts on is what is actually installed rather than what your checkout currently says.

## Template substitution

Every template (the branch's `.env.*`, `caddy.conf`, and each `*.service` unit) is rendered in a single pass with the same vars:

1. **Git** (computed locally): `{{GIT_BRANCH}}`, `{{GIT_BRANCH_UNDERSCORE}}`
2. **App** (derived from `domain:`): `{{APP}}`, `{{APP_UNDERSCORE}}`, `{{HASH}}` (`h` + first 6 SHA-256 hex chars of the main domain), `{{TAG}}` (`s` + first 5 SHA-256 hex chars of the main domain)
3. **`.yaml`**: every non-behavioral key uppercased -- `{{SERVER}}`, `{{DOMAIN}}`, etc.
4. **Ports**: `{{PORT}}` and any `{{PORT_*}}` -- reused from the existing `.env`, or first free ports in `3010..3990` step 10
5. **Derived**: `{{DIR}}`, `{{LOG_DIR}}`, `{{LOG_NAME}}`, `{{SERVICE_USER}}`, `{{SERVICE_HOME}}`, plus `{{RUBY}}`/`{{RUBY_DIR}}` only when a template references them

An unresolved `{{VAR}}` is an error, not a silently shipped placeholder; `doctor` runs the same check locally before you deploy.

`.env` does **not** feed back into the placeholder namespace.
It is a runtime-only file -- rendered once, uploaded, and read by the running app at boot.
`caddy.conf` / `systemd.service` cannot reference keys defined inside `.env`; if you need a value in both places put it in `.yaml` (so it becomes `{{KEY}}`) and the app's `.env` can reference the same `{{KEY}}` if you want it duplicated there.

Behavioral keys (`service_user`, `remote_base`, `service_prefix`, `on_fail`, `src`) are excluded from the placeholder namespace - they configure the engine, not the templates.
`service_user` is re-exposed as the engine-derived `{{SERVICE_USER}}` / `{{SERVICE_HOME}}` so units can run as the right user.
`PORT*` are engine-provided, so units/caddy may reference `{{PORT_*}}` without declaring them in `.yaml`.

## Deploy flow

```
 1. read config/deploy/.yaml and optional config/deploy/src
 2. derive <app_domain> from yaml `domain:` (first comma-split, strip leading "*.")
 2b. resolve the branch: main serves `domain:`, any other branch gets `branch_domain:`
     -> app = <app_domain>-<branch>, dir = <remote_base>/<app_domain>/<branch>
 3. pick the env template: .env.<branch> if present, else master|main -> .env.main, else .env.default
 4. local_before.sh   (LOCAL, if present; non-zero exit -> abort)
 5. ensure remote dirs (service_user-owned)
 6. take the deploy lock (<app_dir>/.deploy.lock)
 7. wipe stale new-release/ (from a prior failed deploy, if any)
 8. allocate / reuse every PORT*

 9. rsync code to new-release/
10. symlink tmp, log, .env into new-release/
11. mise install, if the app ships a mise.toml
12. render templates (.env + .env.local overlay, caddy.conf, each *.service unit)
13. upload rendered artifacts to <app_dir>/ and to new-release/.lux-deploy/
14. remote_before.sh  (SERVER, in new-release/, .env sourced; abort on failure -- new-release/ kept for inspection)
                       This is where your app installs gems / npm / go build / migrations / asset compile.
                       lux-deploy ships nothing language-specific past this point.
15. release swap:  rm old-release; mv release old-release; mv new-release release
16. ensure <app_dir>/log exists, if caddy.config emits a JSONL access log
17. install symlinks under /etc/systemd/system and /etc/caddy/sites
18. systemctl daemon-reload + enable/restart every service
19. health gate: wait for every PORT* to be listening, assert every unit is active
                       (or run config/deploy/health.sh instead, if it exists)
20. systemctl reload caddy   <- traffic only now points at the new release
21. remote_after.sh   (SERVER, in release/, .env sourced)
22. write <app_dir>/lux-deploy.yaml and release/.lux-deploy/lux-deploy.yaml (manifest)
23. local_after.sh    (LOCAL, if present; non-zero exit -> warn, deploy is already live)
24. release the deploy lock
```

Steps 19-21 share one failure policy: non-zero fails the command, and with `on_fail: rollback` the previous release is restored first.

Render happens *after* rsync because the ruby probe globs for a mise-installed ruby, and mise only knows what to install once the app's `mise.toml` is on the box.

Every lifecycle hook step is always announced - if the file is missing the line reads e.g. `==> run config/deploy/local_before.sh (not defined, skipping)` so absence is visible, not silent.

On any failure between step 9 and step 14, `release/` is untouched and `new-release/` is left in place on the server (path printed in the error).
`lux-deploy server:ssh` to inspect; the next `lux-deploy up` wipes `new-release/` at step 7.
Run `lux-deploy on:remote:before` to re-run the server-side pre-swap hook against the current `new-release/`.
If the health gate or `remote_after.sh` fails (steps 19-21), the swap has already happened: the command fails and the new release stays in place unless `on_fail: rollback` is set.
Caddy is only reloaded after the gate passes, so on a first deploy - or any deploy that changed `caddy.conf` - traffic is never pointed at a release that did not come up.

## Notes

* `lux-deploy destroy` prompts `type '<domain>' to confirm` unless `--yes`, and removes only the current branch.
* `lux-deploy redeploy` wipes this branch's dir, so its `PORT*` are re-allocated fresh.
* Concurrent deploys of the same branch are refused: `up` takes `<app_dir>/.deploy.lock` and reports who holds it. A lock older than 60 minutes is presumed dead and broken automatically; `--force` breaks one on demand.
* The swap at step 15 is two `mv` calls, so there is a sub-second window in which `release/` does not exist. A unit that crash-restarts inside that window fails to start and is picked up by the next `Restart=always` cycle.

## Upgrading to 0.3.0

Three renames and one moved directory. Nothing on a running host changes until you deploy.

**1. Env templates.** `up` aborts with a `mv` hint if it finds the old names:

```sh
git mv config/deploy/.env         config/deploy/.env.main
git mv config/deploy/.env.staging config/deploy/.env.default
```

`.env.default` no longer needs to build its own hostname - `DOMAIN={{DOMAIN}}` is already the branch host. Delete any `DOMAIN={{GIT_BRANCH}}.staging.{{DOMAIN}}` line.

**2. Production moves one level down** - run `lux-deploy migrate` once per app, from the branch that deploys it (usually `main`):

```sh
lux-deploy migrate   # moves apps/example.com/ -> apps/example.com/main/, drops the old unit + caddy file
lux-deploy up        # re-renders the artifacts for the new paths and starts the new unit
lux-deploy status    # confirm
```

`migrate` moves the payload rather than rebuilding it, so allocated ports, `.env`, `.env.local`, `release/` and `old-release/` all survive. The site is down between the two commands - the rendered unit still points at the old paths until `up` re-renders it - so expect a few seconds, not a maintenance window.

This is not optional. The pre-0.3 caddy file (`example.com.caddy`) and the new one (`example.com-main.caddy`) declare the same domains, and Caddy rejects that outright:

```
Error: adapting config using caddyfile: ambiguous site definition: example.com
```

Caddy validates before swapping, so nothing breaks - but the config is rejected as a whole, which would take every other site on the host with it. `up` therefore refuses to run while the old layout is present and points you here. Port allocation reads both layouts, so a not-yet-migrated app keeps its ports reserved in the meantime.

That guard only looks where *this* app would live, so it misses a conflict parked under another name - most often an app whose `domain:` was changed at the same time as the upgrade, leaving its old dir and site file behind under the old name. `migrate` does not cover a rename either: it moves `<remote_base>/<old-domain>/`, which no longer matches. Move that one by hand, then delete the stale `/etc/caddy/sites/<old-domain>.caddy` and its units.

As a backstop, `up` compares its rendered site addresses against every file already in `/etc/caddy/sites/` and refuses if anything else claims one, before it installs or swaps anything:

```
ERROR: caddy site conflict on deb1 - refusing to install sohotasks.com-main.caddy.
    /etc/caddy/sites/soho_tasks.caddy also claims http://sohotasks.com, http://*.sohotasks.com
```

**3. `prepare:nginx` is gone.** It installed nginx but no deploy could ever emit an nginx site file. See *Why Caddy, and only Caddy* above.

Also new in 0.3.0: the health gate (`health:`, `boot_timeout:`, `health_path:`, `config/deploy/health.sh`), `rollback` + `on_fail:`, `env:list/get/set/edit` over a server-side `.env.local`, `status`, `host:apps`, `caddy:doctor`, and a deploy lock.
