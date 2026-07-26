require 'yaml'

module LuxDeploy
  # What is actually installed on the host, as opposed to what the local
  # checkout thinks. <app_dir>/lux-deploy.yaml is the record - it lists every
  # unit that was really wired up, including ones whose *.service file has
  # since been deleted or "!"-disabled locally.
  #
  # Every deploy also snapshots its artifacts into <release>/.lux-deploy/, so
  # the same reader serves rollback: point `dir:` at a release's snapshot to
  # see the manifest that shipped with it.
  module RemoteState
    SNAPSHOT_DIR ||= '.lux-deploy'

    module_function

    # Parsed manifest hash, or nil when absent/unparseable. Never raises -
    # every caller has a local fallback.
    def read_manifest(ctx, dir: nil)
      path = File.join(dir || ctx.app_dir, Manifest::FILENAME)
      body = ctx.ssh.run("cat #{Shellwords.escape(path)} 2>/dev/null || true",
                         as: :service, allow_fail: true)
      return nil if body.to_s.strip.empty?
      parse(body)
    end

    # Hash or nil - a hand-edited or truncated manifest must not take a
    # command down, every caller has a local fallback.
    def parse(body)
      data = YAML.safe_load(body.to_s)
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    # Services as installed on the host. Falls back to the local
    # config/deploy/*.service scan when there is no usable manifest (an app
    # deployed before manifests existed, or a dry run).
    def services(ctx, manifest = nil)
      manifest ||= read_manifest(ctx)
      found = manifest_services(manifest)
      found.empty? ? ctx.services : found
    end

    # Context::Service list rebuilt from a manifest's `services:` section.
    # `template` is nil - a manifest records what was installed, not which
    # local file rendered it.
    # Every reader below takes whatever YAML happened to be on the box, so a
    # hand-edited or half-written manifest must degrade to the local fallback
    # rather than crash destroy/rollback/status.
    def manifest_services(manifest)
      services = manifest.is_a?(Hash) ? manifest['services'] : nil
      return [] unless services.is_a?(Hash)

      services.filter_map do |name, info|
        next unless info.is_a?(Hash)
        unit     = info['unit'].to_s.sub(/\.service\z/, '')
        artifact = File.basename(info['source'].to_s)
        next if unit.empty? || artifact.empty? || artifact == '.'
        Context::Service.new(name.to_s, nil, artifact, unit, name.to_s == 'web')
      end
    end

    # Short git commit recorded in a manifest, for human-facing output.
    def commit(manifest)
      git = manifest.is_a?(Hash) ? manifest['git'] : nil
      return 'unknown' unless git.is_a?(Hash)
      short = (git['commit_short'] || git['commit']).to_s[0, 12]
      out   = [short, git['commit_subject'].to_s].reject(&:empty?).join(' ')
      out.empty? ? 'unknown' : out
    end
  end
end
