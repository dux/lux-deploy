#!/usr/bin/env bash
# local_before.sh - lux-deploy lifecycle hook (LOCAL, before rsync).
#
# Runs on YOUR machine (or CI runner - wherever lux-deploy is invoked),
# in the project root, BEFORE any remote work begins. Use for pre-flight
# gates that should fail fast on the dev side and for local pre-deploy
# preparation:
#   - run local tests, lint, bundle audit
#   - check `git status` is clean
#   - check CI passed for the current SHA
#   - dry-run a migration
#   - bundle cache --no-install   # ship .gem files via the rsync so the
#                                 # server skips downloads for platform-
#                                 # matching gems
#
# Non-zero exit aborts the deploy before any code is rsynced. Optional -
# delete the file if you don't want a local gate.
set -euo pipefail

# Cache gems locally so the rsync ships vendor/cache/*.gem to the server.
# Native gems (pg, nokogiri, etc.) cached on macOS won't match Debian, so
# they get re-fetched and built natively on the server. Non-fatal if the
# local bundle isn't installable for any reason.
bundle cache --no-install || echo "bundle cache failed, continuing without local cache"
