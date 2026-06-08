#!/usr/bin/env bash
# remote_after.sh - lux-deploy lifecycle hook (SERVER, in release).
#
# Runs ON THE SERVER inside release/, as the service user, after the
# atomic swap and systemd reload. The new release is already serving
# traffic. The rendered .env is sourced into the shell before this
# script runs, so DB_URL, SECRET, RUBY, RUBY_DIR, PORT, etc. are
# already exported. Use for:
#   - post-deploy verification / smoke checks
#   - post-deploy notifications (Slack, Discord, ...)
#   - cache warmup
#   - external API calls
#   - cleanup
#
# Non-zero exit fails the deploy command but does NOT roll back (the new
# release is already live; rolling back here would require a second swap).
# Optional - delete the file if you don't want a server hook.
#
# lux-deploy runs this hook with `set -euo pipefail` already enabled.
