#!/usr/bin/env bash
# local_after.sh - lux-deploy lifecycle hook (LOCAL, after success).
#
# Runs on YOUR machine, in the project root, AFTER the remote deploy
# succeeded and the manifest was written. The deploy is already live, so
# this is for finishing touches on the local side:
#   - post-deploy notifications (Slack, Discord, ...)
#   - clean up build artifacts produced by local_before.sh
#     (e.g. rm -rf vendor/cache, drop built .gem files)
#   - tag the release / bump a changelog
#   - open the deployed URL
#
# Non-zero exit warns but does NOT roll back (the deploy is already live).
# Optional - delete the file if you don't want a local post-hook.
#
# lux-deploy runs this hook with `set -euo pipefail` already enabled.
