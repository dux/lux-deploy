#!/usr/bin/env bash
# after_server.sh - lux-deploy lifecycle hook (SERVER).
#
# Runs ON THE SERVER inside release/, as the service user, after the
# atomic swap and systemd reload. The new release is already serving
# traffic. The rendered .env is symlinked in, so DB_URL, SECRET, etc.
# are available. Use for:
#   - post-deploy notifications (Slack, Discord, ...)
#   - cache warmup
#   - external API calls
#   - cleanup
#
# Non-zero exit warns but does NOT roll back (the new release is already
# live; rolling back here would require a second swap). Optional - delete
# the file if you don't want a server hook.
set -euo pipefail
