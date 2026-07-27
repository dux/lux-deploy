require_relative 'test_helper'

# The gather is one ssh round trip returning marked sections. Everything the
# TUI and host:apps show comes out of this parse, so it is the part worth
# testing - the render loop is not.
class HostStateTest < Minitest::Test
  BASE ||= '/home/deployer/apps'.freeze

  def config(raw = {}) = LuxDeploy::Config.new({ 'remote_base' => BASE }.merge(raw))

  def manifest(app:, branch: 'main', commit: 'abc1234', port: 3010, units: { 'web' => nil }, url: nil)
    services = units.map do |name, unit|
      "  #{name}:\n    unit: #{unit || "web-#{app}"}.service\n    source: /x/systemd.service\n"
    end.join
    <<~YAML
      ---
      deployed_at: '2026-07-27T08:11:39Z'
      app: #{app}
      url: #{url || "https://#{app}"}
      git:
        branch: #{branch}
        commit_short: #{commit}
      deploy:
        app_dir: "#{BASE}/#{app}/#{branch}"
        ports:
          PORT: #{port}
      services:
      #{services}
    YAML
  end

  def raw(units:, ports:, apps:)
    out = +"__UNITS__\n"
    units.each { |line| out << line << "\n" }
    out << "__PORTS__\n"
    ports.each { |p| out << p.to_s << "\n" }
    apps.each { |path, body| out << "__APP__ #{path}\n" << body }
    out
  end

  def test_a_healthy_app_parses
    apps, ports = LuxDeploy::HostState.parse(
      raw(units: ['web-vibe|active|0'], ports: [3010],
          apps: { "#{BASE}/vibe/main/lux-deploy.yaml" => manifest(app: 'vibe', units: { 'web' => 'web-vibe' }) }),
      config
    )

    assert_equal 1, apps.size
    app = apps.first
    assert_equal 'vibe',    app.name
    assert_equal 'main',    app.branch
    assert_equal 'abc1234', app.commit
    assert_equal ['3010'],  app.ports
    assert app.units.first.healthy?
    assert_includes ports, '3010'
    refute app.legacy
  end

  # The case that went unseen for six weeks: is-active says activating, which
  # a naive reader treats as "starting up".
  def test_a_crash_looping_unit_is_not_healthy
    apps, = LuxDeploy::HostState.parse(
      raw(units: ['web-authcog|active|0', 'web-authcog-job|activating|691459'], ports: [3020],
          apps: { "#{BASE}/authcog/main/lux-deploy.yaml" =>
                  manifest(app: 'authcog', units: { 'web' => 'web-authcog', 'job' => 'web-authcog-job' }) }),
      config
    )

    job = apps.first.units.find { |u| u.name.end_with?('-job') }
    refute job.healthy?
    assert_equal 691_459, job.restarts
  end

  # An "active" unit that has already died and been restarted is not healthy -
  # NRestarts is reset by an explicit restart, so nonzero means it crashed.
  def test_active_but_restarted_is_not_healthy
    apps, = LuxDeploy::HostState.parse(
      raw(units: ['web-a|active|4'], ports: [],
          apps: { "#{BASE}/a/main/lux-deploy.yaml" => manifest(app: 'a', units: { 'web' => 'web-a' }) }),
      config
    )
    refute apps.first.units.first.healthy?
  end

  # The manifest lists a unit systemd has never heard of - its file was removed
  # by hand, or a deploy half-failed.
  def test_a_unit_systemd_does_not_know_is_missing
    apps, = LuxDeploy::HostState.parse(
      raw(units: [], ports: [],
          apps: { "#{BASE}/a/main/lux-deploy.yaml" => manifest(app: 'a', units: { 'web' => 'web-a' }) }),
      config
    )
    assert apps.first.units.first.missing?
    refute apps.first.units.first.healthy?
  end

  # vibe's case: a unit left over from an older deploy that no manifest claims.
  # It must not silently vanish from the view.
  def test_unclaimed_units_are_collected
    apps, = LuxDeploy::HostState.parse(
      raw(units: ['web-a|active|0', 'web-ghost-job|failed|12'], ports: [],
          apps: { "#{BASE}/a/main/lux-deploy.yaml" => manifest(app: 'a', units: { 'web' => 'web-a' }) }),
      config
    )

    orphan = apps.last
    assert_equal '(unclaimed units)', orphan.name
    assert_equal ['web-ghost-job'], orphan.units.map(&:name)
  end

  # A manifest one level under remote_base is the pre-0.3 flat layout.
  def test_the_legacy_layout_is_flagged
    apps, = LuxDeploy::HostState.parse(
      raw(units: ['web-old|active|0'], ports: [],
          apps: { "#{BASE}/old/lux-deploy.yaml" => manifest(app: 'old', units: { 'web' => 'web-old' }) }),
      config
    )
    assert apps.first.legacy
  end

  # A half-written or hand-edited manifest must drop out, not take the view down.
  def test_an_unparseable_manifest_is_skipped
    apps, = LuxDeploy::HostState.parse(
      raw(units: [], ports: [],
          apps: { "#{BASE}/bad/main/lux-deploy.yaml" => "---\n\tnot: [valid\n",
                  "#{BASE}/a/main/lux-deploy.yaml"   => manifest(app: 'a', units: { 'web' => 'web-a' }) }),
      config
    )
    assert_equal %w[a], apps.map(&:name)
  end

  def test_empty_host_is_not_an_error
    apps, ports = LuxDeploy::HostState.parse("__UNITS__\n__PORTS__\n", config)
    assert_empty apps
    assert_empty ports
  end

  # ss output is what tells a listening port from a merely allocated one.
  def test_ports_come_from_ss_not_the_manifest
    apps, ports = LuxDeploy::HostState.parse(
      raw(units: ['web-a|active|0'], ports: [3010],
          apps: { "#{BASE}/a/main/lux-deploy.yaml" => manifest(app: 'a', port: 3999, units: { 'web' => 'web-a' }) }),
      config
    )
    assert_equal ['3999'], apps.first.ports
    refute_includes ports, '3999'
  end
end
