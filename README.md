# lux-deploy

Stupid-simple deploy via SSH + rsync.
No Docker required. No registry. No JSON.

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
Drop `docker-compose.yaml` and it is a container deploy.
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
lux-deploy prepare:docker    # install Docker + compose, let the service user reach the daemon
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
For a [container deploy](#containers) it also prints a `containers` block - one line per compose service with its state and health, which is the thing `systemctl is-active` cannot tell you.
`host:apps` reads every `<remote_base>/*/lux-deploy.yaml` in one round trip.

## Commands

| command                | purpose |
| ---------------------- | ------- |
| `lux-deploy up`        | deploy current branch |
| `lux-deploy rollback`  | restore the previous release |
| `lux-deploy migrate`   | move a pre-0.3 flat app dir into the `<domain>/<branch>` layout |
| `lux-deploy tui`       | live view of every app on the host: state, restart counts, ports, logs, restart/stop/start |
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
| `lux-deploy prepare:docker` | install Docker + compose, add the service user to the docker group |
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
  docker-compose.yaml    # optional: present means this is a container deploy
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

## Containers

Docker is not required, but it is supported the same way everything else here is: by a file.
Put a `docker-compose.yaml` in `config/deploy/` and this is a container deploy.
There is no `mode:` key and no adapter class - the engine still rsyncs a release, renders templates, installs a systemd unit and a caddy site file, and gates on health.
It just knows about one more template, and looks one level deeper when it checks that the release came up.

```sh
lux-deploy prepare:docker      # once per host: engine + compose v2, service user in the docker group
lux-deploy app:init            # ships !docker-compose.yaml; rename it to enable
```

`docker-compose.yaml`, `docker-compose.yml`, `compose.yaml` and `compose.yml` are all recognised, in that order.
Two of them present is an error rather than a coin flip.
Prefixing with `!` disables it like any other file, and turns the app back into an ordinary deploy.

What changes once that file exists:

* It is **rendered** with exactly the same vars as the units - `{{PORT}}`, `{{DIR}}`, `{{APP}}`, `{{GIT_COMMIT_SHORT}}`. An unresolvable `{{VAR}}` fails the deploy instead of shipping literally, and `doctor` catches it locally first.
* `{{COMPOSE_FILE}}` appears in the placeholder namespace, holding the absolute remote path. Use it in the unit so the filename lives in one place.
* It is uploaded to `<app_dir>/` **before `remote_before.sh` runs**, so that hook can `docker compose pull` or `build` against the file this deploy will actually run.
* It is snapshotted into `release/.lux-deploy/`, so `rollback` puts it back with the code rather than leaving the new stack definition over old code.
* Its `{{PORT*}}` placeholders feed port allocation, same as a unit's.
* The health gate gains a container assertion, and `status` grows a `containers` block.
* `doctor` adds a compose-plugin host check, and two local checks that are hard failures.

### A worked example: web + postgres

From nothing to a deployed two-container stack.
Six files, each shown in full - nothing is elided, and there is no seventh.

```sh
lux-deploy prepare:docker                # once per host
lux-deploy app:init                      # writes config/deploy/
mv config/deploy/'!docker-compose.yaml' config/deploy/docker-compose.yaml
```

**`config/deploy/.yaml`** - the two required keys, plus an HTTP probe on top of the port wait:

```yaml
server: srv.example.com
domain: example.com, www.example.com
health_path: /up
```

**`config/deploy/.env.main`** - the *shape* of the runtime env.
It is rendered fresh on every deploy, so nothing secret lives here; the two empty keys are filled in on the server once and survive every later deploy.

```sh
RACK_ENV=production
DOMAIN={{DOMAIN}}
POSTGRES_DB=app
POSTGRES_USER=postgres

# Handed to remote_before.sh, which runs with this file sourced and exported.
# `docker compose` honours COMPOSE_FILE natively, so the hook needs no -f.
COMPOSE_FILE={{COMPOSE_FILE}}
DEPLOY_TAG={{GIT_COMMIT_SHORT}}

# Empty on purpose. These two are set once on the server and survive every
# deploy - the repo holds the shape of the env, the box holds the values:
#   lux-deploy env:set POSTGRES_PASSWORD=$(openssl rand -hex 16)
#   lux-deploy env:set DB_URL=postgresql://postgres:<that>@db:5432/app
POSTGRES_PASSWORD=
DB_URL=
```

**`config/deploy/docker-compose.yaml`** - both services read the same `.env`, so no secret is ever interpolated into this file:

```yaml
name: {{APP}}

services:
  web:
    image: example-app:{{GIT_COMMIT_SHORT}}
    restart: unless-stopped
    env_file: {{DIR}}/.env
    ports:
      - '127.0.0.1:{{PORT}}:8080'
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ['CMD-SHELL', 'wget -qO- http://127.0.0.1:8080/up || exit 1']
      interval: 5s
      start_period: 20s
      retries: 5

  db:
    image: postgres:17-alpine
    restart: unless-stopped
    env_file: {{DIR}}/.env
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $POSTGRES_USER']
      interval: 5s
      retries: 10

volumes:
  pgdata:
```

**`config/deploy/systemd.service`** - delete the `User=` and `Environment="PATH=..."` lines `app:init` shipped; compose talks to the root daemon:

```ini
[Unit]
Description={{DOMAIN}}
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory={{DIR}}
ExecStart=/usr/bin/docker compose -f {{COMPOSE_FILE}} up
ExecStop=/usr/bin/docker compose -f {{COMPOSE_FILE}} down
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**`config/deploy/remote_before.sh`** - the build step, which is the only place lux-deploy has an opinion about your language (none):

```sh
# Runs on the server in new-release/, with the rendered .env exported - so
# DEPLOY_TAG and COMPOSE_FILE are already set. Non-zero here aborts the
# deploy and release/ keeps serving.
docker build -t "example-app:$DEPLOY_TAG" .
docker compose run --rm web bin/rails db:migrate
```

**`config/deploy/caddy.conf`** - unchanged from a non-container app, because Caddy has no idea a container is involved:

```
{{DOMAIN}} {
  reverse_proxy localhost:{{PORT}} {
    lb_try_duration 10s
  }
}
```

Then:

```
$ lux-deploy env:set POSTGRES_PASSWORD=$(openssl rand -hex 16)
$ lux-deploy doctor
$ lux-deploy up
==> deploy example.com-main (branch main) -> srv.example.com
==> ensure remote dirs
==> take deploy lock (/home/deployer/apps/example.com/main/.deploy.lock)
==> allocate ports
    allocated PORT=3010
==> rsync code
==> mise install (pinned toolchain)
==> render templates
==> write rendered .env + docker-compose.yaml
==> run config/deploy/remote_before.sh (server, in new-release, .env sourced)
==> release swap
==> write rendered systemd.service / caddy.config
==> install systemd + caddy symlinks
==> restart services
==> health gate: wait for PORT=3010 (30s)
==> health gate: compose stack /home/deployer/apps/example.com/main/docker-compose.yaml (30s)
==> reload caddy
==> write lux-deploy.yaml
==> done. https://example.com (PORT=3010)
```

Note the order: the compose file is written *before* `remote_before.sh`, and the container gate runs *after* the port wait.

This is what lands at `<app_dir>/docker-compose.yaml` - the file compose actually runs:

```yaml
name: example.com-main

services:
  web:
    image: example-app:50f7fc0
    restart: unless-stopped
    env_file: /home/deployer/apps/example.com/main/.env
    ports:
      - '127.0.0.1:3010:8080'
...
```

`50f7fc0` is the commit being deployed, so the image tag is immutable and rolls back with the code.
`3010` was allocated once and is reused on every later deploy, which is why the Caddy upstream never changes.

`status` reports the stack, not just the unit:

```
$ lux-deploy status
  services
    web-example.com-main active
  ports
    PORT=3010 listening
  containers  /home/deployer/apps/example.com/main/docker-compose.yaml
    web                  running      healthy
    db                   running      healthy
  rollback    available (lux-deploy rollback)
```

And when the stack does not come up, the deploy fails instead of reporting success:

```
$ lux-deploy up
==> health gate: compose stack /home/deployer/apps/example.com/main/docker-compose.yaml (30s)
  --- docker compose -f /home/deployer/apps/example.com/main/docker-compose.yaml logs --tail 40 db ---
  db-1  | FATAL:  password authentication failed for user "postgres"
ERROR: health gate failed: db is restarting (/home/deployer/apps/example.com/main/docker-compose.yaml).
  The unit is active - compose is running - but the stack is not.
```

The unit *is* active and port 3010 *is* bound - `web` came up fine.
Without the container check this deploy reports success and serves 500s.

### The rules

**`name:` is required, and `doctor` fails without it.**
`docker compose -f <file>` derives the project name from the file's directory, which here is `<remote_base>/<domain>/<branch>`.
Without a `name:` every app on the host deploying `main` shares the compose project `main` - `docker compose ps` in one lists another's containers, and `docker compose down` in one can tear another down.
The engine will not inject `-p` or rewrite your file; it refuses to deploy instead.

**Secrets do not go in this file.**
It is rendered from the repo and uploaded 0644, exactly like the unit files.
Values belong in the branch's `.env.*` template and in `lux-deploy env:set`, reached from compose via `env_file: {{DIR}}/.env`.

### What the health gate proves

The stock gate waits for every `PORT*` to be listening, then asserts every unit is `active` with zero restarts.
That is not enough for a stack: compose stays cheerfully active while postgres crash-loops behind a web container that already bound its port.

So for a container deploy the gate also runs `docker compose ps` and requires every service to be `running`, and - where the image declares a `HEALTHCHECK` - `healthy`.
It polls rather than samples, on the same `boot_timeout` budget, because a container with a `start_period` is still `starting` for a while after the port opens.
Note that makes `boot_timeout` per phase: a thoroughly broken deploy can wait it out twice.

Two deliberate passes:

* A service with no `HEALTHCHECK` passes on `running` alone. Inventing a verdict there would fail every stock image.
* A service that `exited 0` passes - that is a one-shot (migrations, an asset build) that is supposed to be finished by the time the gate looks. A non-zero exit fails.

On failure the deploy prints `docker compose logs` for the failing services only.
`journalctl` is useless here: for a `compose up -d` unit the container's stdout never reaches the journal.

`health: false` and `config/deploy/health.sh` both override this exactly as they override the port wait - `health.sh` replaces the built-in gate entirely, containers included.

### Images and rollback

Use an immutable per-commit tag (`{{GIT_COMMIT_SHORT}}`), and build or pull it in `remote_before.sh` - the compose file is already on the box when that hook runs.
`rollback` restores the unit, the `.env` and the compose file together, so the image tag goes back with the code rather than drifting from it.

That only holds while the previous image is still on the box.
An aggressive `docker image prune` leaves you with a rollback that swaps the code back and then cannot start.

Known limits, none of which the engine papers over:

* The engine never runs `docker compose up` / `pull` / `down` itself. The unit is the interface; that is the point.
* A deploy that dies between the artifact upload and the release swap leaves `<app_dir>/docker-compose.yaml` newer than `release/`. `.env` has always had the same window.
* `config/deploy/docker-compose.yaml` is also rsynced into the release **unrendered**, so `release/config/deploy/docker-compose.yaml` still shows `{{PORT}}`. Run compose against `{{COMPOSE_FILE}}`, never against the copy in the release.
* Rootless Docker (a per-user daemon) is not covered - `prepare:docker` adds the service user to the `docker` group, and the gate probes the root daemon.
* `podman` is detected but not driven: `prepare:docker` and the gate both shell out to `docker`. Use `health.sh` as the escape hatch.

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

Every template (the branch's `.env.*`, `caddy.conf`, each `*.service` unit, and the compose file if there is one) is rendered in a single pass with the same vars:

1. **Git** (computed locally): `{{GIT_BRANCH}}`, `{{GIT_BRANCH_UNDERSCORE}}`, `{{GIT_BRANCH_SLUG}}`, `{{GIT_COMMIT}}`, `{{GIT_COMMIT_SHORT}}`
2. **App** (derived from `domain:`): `{{APP}}`, `{{APP_UNDERSCORE}}`, `{{HASH}}` (`h` + first 6 SHA-256 hex chars of the main domain), `{{TAG}}` (`s` + first 5 SHA-256 hex chars of the main domain)
3. **`.yaml`**: every non-behavioral key uppercased -- `{{SERVER}}`, `{{DOMAIN}}`, etc.
4. **Ports**: `{{PORT}}` and any `{{PORT_*}}` -- reused from the existing `.env`, or first free ports in `3010..3990` step 10
5. **Derived**: `{{DIR}}`, `{{LOG_DIR}}`, `{{LOG_NAME}}`, `{{SERVICE_USER}}`, `{{SERVICE_HOME}}`, plus `{{RUBY}}`/`{{RUBY_DIR}}` only when a template references them, and `{{COMPOSE_FILE}}` only when a compose file is present

An unresolved `{{VAR}}` is an error, not a silently shipped placeholder; `doctor` runs the same check locally before you deploy.

Careful with `{{TAG}}`: it is the domain hash used to name Caddy snippets, nothing to do with git.
The commit is `{{GIT_COMMIT_SHORT}}`, which is what you want for a container image tag:

```ini
# config/deploy/systemd.service - ExecStart is yours, it need not be a ruby process
ExecStart=/usr/bin/docker run --rm --name {{APP_UNDERSCORE}} \
  -p 127.0.0.1:{{PORT}}:8080 --env-file {{DIR}}/.env myapp:{{GIT_COMMIT_SHORT}}
```

Put `DEPLOY_SHA={{GIT_COMMIT_SHORT}}` in the branch's `.env.*` and `remote_before.sh` can build that same tag -- hooks run with `.env` sourced.
Rollback restores the unit, the `.env` and the compose file from `release/.lux-deploy/`, so the image tag goes back with the code rather than drifting from it.
That only holds for an immutable per-commit tag, and only while the previous image is still on the box -- an aggressive `docker image prune` will leave you with a rollback that swaps code back and then cannot start.

For a multi-container app write a compose file instead of a long `docker run` line; see [Containers](#containers).

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
12. render templates (.env + .env.local overlay, caddy.conf, each *.service unit, the compose file)
13a. upload .env and the compose file to <app_dir>/ and new-release/.lux-deploy/
                       Only these two, and only because the hook needs them: the release symlinks
                       to .env, and `docker compose pull|build` needs the file it will run.
14. remote_before.sh  (SERVER, in new-release/, .env sourced; abort on failure -- new-release/ kept for inspection)
                       This is where your app installs gems / npm / go build / migrations / asset compile.
                       lux-deploy ships nothing language-specific past this point.
15. release swap:  rm old-release; mv release old-release; mv new-release release
13b. upload the remaining artifacts (caddy.config, each unit) -- held back until the
                       release they describe is actually live, because the installed unit is a
                       symlink into <app_dir> and a reboot would otherwise start the wrong code
16. ensure <app_dir>/log exists, if caddy.config emits a JSONL access log
17. install symlinks under /etc/systemd/system and /etc/caddy/sites
18. systemctl daemon-reload + enable/restart every service
19. health gate: wait for every PORT* to be listening, assert every unit is active,
                       and for a container deploy assert every compose service is running/healthy
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
