#!/usr/bin/env bash
# before_local.sh - lux-deploy lifecycle hook (LOCAL).
#
# Runs on YOUR machine (or CI runner - wherever lux-deploy is invoked),
# in the project root, BEFORE any remote work begins. Use for pre-flight
# gates that should fail fast on the dev side:
#   - run local tests, lint, bundle audit
#   - check `git status` is clean
#   - check CI passed for the current SHA
#   - dry-run a migration
#
# Non-zero exit aborts the deploy before any code is rsynced. Optional -
# delete the file if you don't want a local gate.
set -euo pipefail
