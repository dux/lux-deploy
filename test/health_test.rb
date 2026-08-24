require_relative 'test_helper'

class HealthConfigTest < Minitest::Test
  def config(raw = {}) = LuxDeploy::Config.new(raw)

  def test_health_is_on_unless_explicitly_false
    assert config.health?
    assert config('health' => true).health?
    refute config('health' => false).health?
  end

  def test_boot_timeout_defaults_and_rejects_nonsense
    assert_equal 30, config.boot_timeout
    assert_equal 5,  config('boot_timeout' => 5).boot_timeout
    assert_equal 30, config('boot_timeout' => 0).boot_timeout
    assert_equal 30, config('boot_timeout' => -1).boot_timeout
    assert_equal 30, config('boot_timeout' => 'nope').boot_timeout
  end

  def test_health_path_is_normalized_to_a_leading_slash
    assert_nil config.health_path
    assert_nil config('health_path' => '  ').health_path
    assert_equal '/up', config('health_path' => 'up').health_path
    assert_equal '/up', config('health_path' => '/up').health_path
  end

  def test_health_keys_stay_out_of_the_placeholder_namespace
    vars = config('health' => false, 'boot_timeout' => 5, 'health_path' => '/up').template_vars

    refute vars.key?(:HEALTH)
    refute vars.key?(:BOOT_TIMEOUT)
    refute vars.key?(:HEALTH_PATH)
  end
end

class HealthGateTest < Minitest::Test
  include ProjectFixture

  def in_app(yaml, ports: { PORT: 3010 })
    in_project({ '.yaml' => yaml, '.env.main' => '', '.env.default' => '', 'caddy.conf' => '', 'systemd.service' => '' }) do
      system('git', 'init', '--quiet', '--initial-branch', 'main', out: File::NULL, err: File::NULL)
      system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
               'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
             'git', 'commit', '--quiet', '--allow-empty', '-m', 'init',
             out: File::NULL, err: File::NULL)
      ctx = LuxDeploy::Context.build({})
      ctx.ports = ports
      yield ctx
    end
  end

  def test_no_http_probe_without_a_health_path
    in_app("server: s\ndomain: example.com\n") do |ctx|
      assert_equal '', LuxDeploy::Commands.http_probe_sh(ctx)
    end
  end

  def test_http_probe_targets_the_web_port_on_loopback
    in_app("server: s\ndomain: example.com\nhealth_path: up\n") do |ctx|
      sh = LuxDeploy::Commands.http_probe_sh(ctx)

      assert_includes sh, 'curl -fsS -m 5 -o /dev/null "http://127.0.0.1:3010/up"'
      assert_includes sh, '__UNHEALTHY__'
    end
  end

  # A worker-only app has no {{PORT}}, so there is nothing to probe over HTTP.
  def test_no_http_probe_without_a_web_port
    in_app("server: s\ndomain: example.com\nhealth_path: /up\n", ports: { PORT_JOB: 3020 }) do |ctx|
      assert_equal '', LuxDeploy::Commands.http_probe_sh(ctx)
    end
  end

  def test_gate_ports_drops_unresolved_entries
    in_app("server: s\ndomain: example.com\n", ports: { PORT: 3010, PORT_JOB: 0 }) do |ctx|
      assert_equal({ PORT: 3010 }, LuxDeploy::Commands.gate_ports(ctx))
    end
  end

  # authcog's job runner sat at 691,459 restarts for six weeks while every
  # deploy reported success: a Restart=always unit flips between active and
  # activating, so is-active alone calls it healthy half the time. NRestarts
  # is reset by the explicit restart the deploy just did, so nonzero means
  # the unit has already died once.
  class Ssh < Struct.new(:out)
    def run(_cmd, **_opts) = out
    def stream(*, **) = nil            # dump_journal, on the failure path
  end

  def gate(lines)
    svc = LuxDeploy::Context::Service
    ctx = Struct.new(:ssh).new(Ssh.new(lines))
    services = lines.lines.map { |l| svc.new('web', nil, nil, l.split.first, true) }
    capture_io { return LuxDeploy::Commands.assert_units_active(ctx, services) }
  end

  def test_an_active_unit_that_never_restarted_passes
    assert_nil gate("web-a active 0\n")
  end

  def test_a_unit_that_already_crash_looped_fails_even_while_active
    err = assert_raises(LuxDeploy::Error) { gate("web-a active 4\n") }
    assert_includes err.message, 'web-a restarted 4x since deploy'
  end

  def test_an_inactive_unit_still_fails
    err = assert_raises(LuxDeploy::Error) { gate("web-a activating 0\n") }
    assert_includes err.message, 'web-a is activating'
  end

  # A unit systemctl knows nothing about reports neither state nor count -
  # skipped rather than reported as a phantom failure.
  def test_an_unknown_unit_is_not_a_failure
    assert_nil gate("web-a\n")
  end

  def test_gate_failure_names_what_went_wrong
    assert_equal 'nothing listening on port 3010',
                 LuxDeploy::Commands.gate_failure("__DOWN__ 3010\n")
    assert_equal 'http://127.0.0.1:3010/up did not answer',
                 LuxDeploy::Commands.gate_failure("__UNHEALTHY__ http://127.0.0.1:3010/up\n")
    assert_equal 'probe did not complete', LuxDeploy::Commands.gate_failure('')
  end
end

# The container half of the gate. `systemctl is-active` says "compose is
# running", which is true of a stack where everything but the web container
# is dead - so these all run the unit past that point.
class ContainerGateTest < Minitest::Test
  include ProjectFixture

  YAML_MIN ||= "server: s\ndomain: example.com\n".freeze

  # Records what it was asked, so a test can assert the gate stayed silent.
  class Ssh
    attr_reader :calls
    def initialize(out = '') = (@out, @calls = out, [])
    def dry_run = false
    def run(cmd, **_opts) = (@calls << cmd; @out)
    def stream(cmd, **_opts) = (@calls << cmd; true)
  end

  def in_app(files, out: '', yaml: YAML_MIN)
    in_project({ '.yaml' => yaml, '.env.main' => '', 'caddy.conf' => '',
                 'systemd.service' => '' }.merge(files)) do
      system('git', 'init', '--quiet', '--initial-branch', 'main', out: File::NULL, err: File::NULL)
      system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
               'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
             'git', 'commit', '--quiet', '--allow-empty', '-m', 'init',
             out: File::NULL, err: File::NULL)
      ctx = LuxDeploy::Context.build({})
      ctx.instance_variable_set(:@ssh, Ssh.new(out))
      ctx.ports = { PORT: 3010 }
      yield ctx
    end
  end

  def ps(*rows) = "__PS__\n#{rows.map(&:to_json).join("\n")}\n"

  def test_a_non_container_app_never_touches_the_daemon
    in_app({}) do |ctx|
      capture_io { LuxDeploy::Commands.assert_containers_healthy(ctx) }
      assert_empty ctx.ssh.calls
    end
  end

  def test_a_healthy_stack_passes
    rows = [{ 'Service' => 'web', 'State' => 'running', 'Health' => 'healthy' },
            { 'Service' => 'db',  'State' => 'running', 'Health' => 'healthy' }]
    in_app({ 'docker-compose.yaml' => "name: x\n" }, out: ps(*rows)) do |ctx|
      capture_io { assert_nil LuxDeploy::Commands.assert_containers_healthy(ctx) }
    end
  end

  def test_a_dead_dependency_fails_and_names_it
    rows = [{ 'Service' => 'web', 'State' => 'running', 'Health' => 'healthy' },
            { 'Service' => 'db',  'State' => 'restarting', 'Health' => '' }]
    in_app({ 'docker-compose.yaml' => "name: x\n" }, out: ps(*rows)) do |ctx|
      err = nil
      capture_io { err = assert_raises(LuxDeploy::Error) { LuxDeploy::Commands.assert_containers_healthy(ctx) } }

      assert_includes err.message, 'db is restarting'
      assert_includes err.message, '/home/deployer/apps/example.com/main/docker-compose.yaml'
      # The container's stdout never reaches the journal for a compose unit,
      # so the failing service's logs are the only useful dump.
      assert ctx.ssh.calls.any? { |c| c.include?('logs --no-color') && c.include?('db') }
    end
  end

  def test_an_empty_stack_is_a_failure_not_a_pass
    in_app({ 'docker-compose.yaml' => "name: x\n" }, out: "__PS__\n") do |ctx|
      err = nil
      capture_io { err = assert_raises(LuxDeploy::Error) { LuxDeploy::Commands.assert_containers_healthy(ctx) } }
      assert_includes err.message, 'compose reported no containers'
    end
  end

  def test_the_probe_polls_on_the_boot_timeout_budget
    in_app({ 'docker-compose.yaml' => "name: x\n" },
           out: ps({ 'Service' => 'web', 'State' => 'running' }),
           yaml: "#{YAML_MIN}boot_timeout: 90\n") do |ctx|
      capture_io { LuxDeploy::Commands.assert_containers_healthy(ctx) }
      probe = ctx.ssh.calls.first

      assert_includes probe, 'ps --all --format json'
      assert_includes probe, '[ $i -ge 90 ]'
      assert_includes probe, 'docker-compose -f'   # v1 fallback
    end
  end

  # Both existing overrides short-circuit before the container gate: health.sh
  # replaces the built-in probe outright, containers included.
  def test_health_false_and_health_sh_both_skip_the_container_gate
    in_app({ 'docker-compose.yaml' => "name: x\n" }, yaml: "#{YAML_MIN}health: false\n") do |ctx|
      capture_io { LuxDeploy::Commands.run_health_gate(ctx, []) }
      assert_empty ctx.ssh.calls
    end

    in_app({ 'docker-compose.yaml' => "name: x\n", 'health.sh' => "exit 0\n" }) do |ctx|
      capture_io { LuxDeploy::Commands.run_health_gate(ctx, []) }
      refute ctx.ssh.calls.any? { |c| c.include?('compose') }
    end
  end
end
