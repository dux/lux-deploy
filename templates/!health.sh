#!/usr/bin/env bash
# health.sh - lux-deploy health gate override (SERVER, in release).
#
# DISABLED. Rename to `health.sh` to use it - the leading "!" is the
# gem-wide disable convention, so this file is ignored and never rsynced
# until you drop the prefix.
#
# lux-deploy already checks the port contract on every deploy: after the
# restart it waits up to `boot_timeout` seconds (default 30) for something
# to be listening on every allocated PORT*, then asserts every unit is
# `active`. Only if that passes does it reload caddy and run
# remote_after.sh. Set `health_path: /up` in .yaml to add an HTTP probe.
#
# This file exists for when that is not the right check. If it is present,
# it REPLACES the built-in gate entirely - lux-deploy runs this and nothing
# else. Non-zero exit means the release is not serving: the deploy fails,
# and with `on_fail: rollback` the previous release is restored.
#
# Runs on the SERVER, as the deployer service user, inside <app_dir>/release/,
# with the rendered .env sourced (so PORT, DB_URL, DOMAIN, ... are exported)
# and `set -euo pipefail` already enabled.
#
# The built-in check, written out - start from this and edit:

for i in $(seq 1 "${BOOT_TIMEOUT:-30}"); do
  if ss -tlnH | awk '{print $4}' | sed 's/.*://' | grep -qx "$PORT"; then
    echo "port $PORT is listening"
    exit 0
  fi
  sleep 1
done

echo "nothing listening on port $PORT after ${BOOT_TIMEOUT:-30}s"
exit 1

# Other things you might check instead:
#   curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$PORT/up"
#   curl -fsS -m 5 -o /dev/null "https://$DOMAIN/up"
#   bundle exec ruby -e 'require "./config/boot"'
#   pg_isready -d "$DB_URL"
