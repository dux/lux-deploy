module LuxDeploy
  # Everything the host is actually doing right now, in one ssh round trip.
  #
  # The manifest says what a deploy *installed*; systemd says what is *running*.
  # Reading only the first is how a job runner crash-looped 691,459 times over
  # six weeks without anyone noticing. This joins the two, plus the listening
  # ports, so a unit that is dead - or one nothing claims any more - is visible
  # rather than inferred.
  module HostState
    App  ||= Struct.new(:name, :branch, :commit, :url, :ports, :units, :deployed_at, :dir, :legacy)
    Unit ||= Struct.new(:name, :state, :restarts) do
      # `active` is not enough on its own: a Restart=always unit flips between
      # active and activating as it crash-loops, so a sample can land on either.
      # NRestarts is reset by an explicit restart, so anything above zero means
      # it has died since something last started it deliberately.
      def healthy? = state == 'active' && restarts.zero?
      def missing? = state == 'missing'
    end

    module_function

    def gather(ssh, config)
      parse(ssh.run(script(config), allow_fail: true), config)
    end

    # Markers rather than one command per fact - refresh is a keystroke, so it
    # has to be a single round trip.
    #
    # Deliberately no container detail here, even for compose apps. Every
    # per-app `docker compose ps` is a ~300ms fork and they would serialize
    # inside this script; at ten apps the TUI's refresh becomes a multi-second
    # stall in an interactive view. `lux-deploy status` shows containers for
    # one app, which is where you look when a unit is active but wrong.
    def script(config)
      base = Shellwords.escape(config.remote_base)
      <<~SH
        echo __UNITS__
        systemctl list-units '#{config.service_prefix}-*' --all --no-legend --plain 2>/dev/null |
          awk '{print $1}' | while read -r u; do
            [ -n "$u" ] || continue
            printf '%s|%s|%s\\n' "${u%.service}" \\
              "$(systemctl is-active "$u" 2>/dev/null)" \\
              "$(systemctl show "$u" -p NRestarts --value 2>/dev/null)"
          done
        echo __PORTS__
        ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u
        for f in #{base}/*/#{Manifest::FILENAME} #{base}/*/*/#{Manifest::FILENAME}; do
          [ -f "$f" ] || continue
          echo "__APP__ $f"
          cat "$f"
        done
      SH
    end

    # Returns [apps, listening_ports]. Apps carry their units; any unit systemd
    # knows about that no manifest claims is collected into a trailing pseudo-app
    # so orphans from an older deploy cannot hide.
    def parse(raw, config)
      head, *chunks = raw.to_s.split(/^__APP__ /)
      units  = parse_units(head)
      ports  = section(head, 'PORTS').to_set
      claimed = []

      apps = chunks.filter_map { |c| parse_app(c, units, claimed, config) }.sort_by(&:name)
      orphans = units.reject { |name, _| claimed.include?(name) }.values
      apps << App.new('(unclaimed units)', '', '', nil, [], orphans, '', '', false) if orphans.any?

      [apps, ports]
    end

    def parse_units(head)
      section(head, 'UNITS').to_h do |line|
        name, state, restarts = line.split('|', 3)
        [name.to_s, Unit.new(name.to_s, state.to_s.strip, restarts.to_i)]
      end
    end

    def parse_app(chunk, units, claimed, config)
      path, _, body = chunk.partition("\n")
      man = RemoteState.parse(body) or return nil

      names = RemoteState.manifest_services(man).map(&:unit)
      claimed.concat(names)

      App.new(
        man['app'].to_s,
        man.dig('git', 'branch').to_s,
        man.dig('git', 'commit_short').to_s,
        man['url'].to_s,
        (man.dig('deploy', 'ports') || {}).values.map(&:to_s),
        names.map { |n| units[n] || Unit.new(n, 'missing', 0) },
        man['deployed_at'].to_s,
        man.dig('deploy', 'app_dir').to_s,
        legacy?(path, config)
      )
    end

    # A manifest sitting one level under remote_base is the pre-0.3 flat layout
    # - <base>/<domain>/ rather than <base>/<domain>/<branch>/. Worth surfacing:
    # deploying such an app writes a second caddy site file for a domain that is
    # already claimed, which caddy rejects host-wide.
    def legacy?(path, config)
      rel = path.to_s.strip.sub(%r{\A#{Regexp.escape(config.remote_base)}/}, '')
      rel.count('/') == 1
    end

    # Lines of one __NAME__ block, up to the next marker or end of input.
    def section(text, name)
      body = text.to_s[/^__#{name}__\n(.*?)(?=^__[A-Z]+__\n|\z)/m, 1]
      body.to_s.lines.map(&:strip).reject(&:empty?)
    end
  end
end
