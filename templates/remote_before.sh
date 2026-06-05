#!/usr/bin/env bash
# remote_before.sh - lux-deploy install/migrate hook (SERVER, in new-release).
#
# Runs on the SERVER, as the deployer service user, inside
# <app_dir>/new-release/, AFTER rsync + .env upload and BEFORE the
# atomic swap. The rendered .env is already sourced into
# the shell, so DB_URL, SECRET, RUBY, RUBY_DIR, PORT, etc. are exported.
#
# This is where YOU install dependencies and do release-time work.
# lux-deploy itself does not bundle/npm/migrate - that is intentional
# so the engine stays language-agnostic.
#
# Non-zero exit aborts the deploy: new-release/ is kept for inspection,
# release/ keeps serving.
set -euo pipefail

# --- Ruby / Bundler defaults --------------------------------------------
# mise prompts y/n the first time it sees a new toml; trust silences it.
[ -f mise.toml ] && mise trust mise.toml >/dev/null 2>&1 || true

# Pin bundler to the version Gemfile.lock was generated with so bundler
# doesn't self-restart on every deploy. --conservative skips the install
# when the version is already present.
BUNDLER_VERSION=$(awk '/^BUNDLED WITH/{getline; print $1}' Gemfile.lock)
gem install bundler -v "$BUNDLER_VERSION" --no-document --conservative

# Bundler 4 default flipped to frozen=true, which fails any deploy where
# Gemfile.lock has source drift. We turn it off so benign drift does not
# kill prod deploys.
bundle config set --local frozen false

# Gems install inside the release dir (per-release, no shared state).
bundle config set --local path vendor/bundle

# Skip dev/test gem groups on prod.
bundle config set --local without 'development test'

# If you ship locally-built .gem files in vendor/cache (e.g. from a
# `local_before.sh` hook that builds path-source gems), their checksums
# will not match the rubygems.org-published versions. Uncomment to trust
# vendor/cache and skip the security check:
#   bundle config set --local disable_checksum_validation true

bundle install --jobs 4 --retry 2

# --- Add your own steps below -------------------------------------------
# Examples:
#   bundle exec rake db:migrate
#   bundle exec rake assets:precompile
#   npm ci --omit=dev && npm run build
#   go build -o app ./cmd/server            # build a Go binary in place
#   bundle exec ruby config/deploy/remote_before.rb   # call into ruby
