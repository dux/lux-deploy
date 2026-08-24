require_relative 'test_helper'

# The docker host checks are gated on the app actually driving containers, so
# every other app is unaffected by them existing.
class DockerDetectionTest < Minitest::Test
  include ProjectFixture

  RUBY_UNIT ||= "[Service]\nExecStart={{RUBY}} -S bundle exec lux s -p {{PORT}}\n".freeze
  DOCKER_UNIT ||= "[Service]\nExecStart=/usr/bin/docker run --rm -p 127.0.0.1:{{PORT}}:8080 app\n".freeze
  COMPOSE_UNIT ||= "[Service]\nExecStart=/usr/bin/docker compose -f {{DIR}}/release/compose.yml up\n".freeze

  def detect(files)
    in_project(files) { |dir| LuxDeploy::Doctor.docker?(dir) }
  end

  def test_a_ruby_unit_does_not_ask_for_docker
    refute detect({ 'systemd.service' => RUBY_UNIT })
  end

  def test_a_docker_unit_is_detected
    assert detect({ 'systemd.service' => DOCKER_UNIT })
  end

  def test_compose_is_detected
    assert detect({ 'systemd.service' => COMPOSE_UNIT })
  end

  def test_an_extra_unit_counts_too
    assert detect({ 'systemd.service' => RUBY_UNIT, 'worker.service' => DOCKER_UNIT })
  end

  # "!" disables a file everywhere else in the engine, so a parked unit must
  # not make doctor start demanding a docker daemon.
  def test_a_disabled_unit_is_ignored
    refute detect({ 'systemd.service' => RUBY_UNIT, '!worker.service' => DOCKER_UNIT })
  end

  # Only *.service files. caddy.conf mentioning docker in a comment, or a hook
  # that happens to shell out to it, is not what gates the host checks.
  def test_non_unit_files_are_not_scanned
    refute detect({ 'systemd.service' => RUBY_UNIT,
                    'caddy.conf'      => "# was docker once\nexample.com {\n}\n" })
  end

  # Substring matches would fire on words like "dockerize" in a comment.
  def test_the_match_is_word_bounded
    refute detect({ 'systemd.service' => "[Service]\n# TODO: dockerise this later\nExecStart=/bin/app\n" })
  end

  # A compose file is the mode switch, so it gates the host checks on its own -
  # the unit might reach compose through a wrapper script.
  def test_a_compose_file_is_enough_on_its_own
    assert detect({ 'systemd.service' => "[Service]\nExecStart=/srv/run.sh\n",
                    'docker-compose.yaml' => "name: x\n" })
  end

  def test_a_parked_compose_file_does_not_demand_a_daemon
    refute detect({ 'systemd.service' => RUBY_UNIT, '!docker-compose.yaml' => "name: x\n" })
  end
end

class DockerChecksTest < Minitest::Test
  include ProjectFixture

  YAML_MIN ||= "server: s\ndomain: example.com\n".freeze

  def checks_for(unit)
    in_project({ '.yaml' => YAML_MIN, 'systemd.service' => unit, 'caddy.conf' => '' }) do
      LuxDeploy::Doctor.build_checks(LuxDeploy::Config.load).map(&:first)
    end
  end

  def test_docker_checks_appear_only_for_a_docker_app
    plain = checks_for("ExecStart={{RUBY}} -S bundle exec lux s\n")
    refute plain.any? { |l| l.include?('docker') }

    docked = checks_for("ExecStart=/usr/bin/docker run app\n")
    assert docked.any? { |l| l.include?('docker installed') }
    assert docked.any? { |l| l.include?('docker daemon running') }
    assert docked.any? { |l| l.include?('docker reachable as') }
  end

  # doctor applies fix commands by itself. Docker group membership is
  # root-equivalent on the host, so that one must stay manual.
  def test_the_group_check_has_no_auto_fix
    entry = in_project({ '.yaml' => YAML_MIN, 'caddy.conf' => '',
                         'systemd.service' => "ExecStart=/usr/bin/docker run app\n" }) do
      LuxDeploy::Doctor.build_checks(LuxDeploy::Config.load).find { |l, _, _| l.include?('docker group') }
    end

    refute_nil entry
    assert_nil entry[2], 'the docker group must never be granted by a routine doctor run'
    assert_includes entry[0], 'prepare:docker'
  end

  # A `docker run` unit needs the engine but not the plugin. Debian stable's
  # docker.io ships no compose v2, so an app that needs it must be told.
  def test_the_compose_plugin_check_is_scoped_to_compose_apps
    run_only = checks_for("ExecStart=/usr/bin/docker run app\n")
    refute run_only.any? { |l| l.include?('compose plugin') }

    with_compose = in_project({ '.yaml' => YAML_MIN, 'caddy.conf' => '',
                                'systemd.service' => "ExecStart=/usr/bin/docker compose up\n",
                                'docker-compose.yaml' => "name: x\n" }) do
      LuxDeploy::Doctor.build_checks(LuxDeploy::Config.load).map(&:first)
    end
    assert with_compose.any? { |l| l.include?('compose plugin') }
  end
end

# `docker compose ps --format json` is the only thing that can tell a stack
# where pg is dead from one where it is not, and its output shape changed
# mid-v2 without ceremony.
class ComposePsTest < Minitest::Test
  def parse(raw) = LuxDeploy::Commands.parse_compose_ps("__PS__\n#{raw}")

  ROW ||= '{"Service":"web","State":"running","Health":"healthy"}'.freeze

  def test_ndjson_one_object_per_line
    rows = parse("#{ROW}\n{\"Service\":\"db\",\"State\":\"running\",\"Health\":\"\"}\n")
    assert_equal %w[web db], rows.map { |r| r['Service'] }
  end

  def test_a_single_array_the_older_v2_shape
    assert_equal ['web'], parse("[#{ROW}]").map { |r| r['Service'] }
  end

  def test_a_pretty_printed_array
    assert_equal ['web'], parse(JSON.pretty_generate(JSON.parse("[#{ROW}]"))).map { |r| r['Service'] }
  end

  # An empty stack and a compose that errored both land here; the caller turns
  # either into "compose reported no containers", which is the honest message.
  def test_garbage_and_emptiness_parse_to_nothing
    assert_empty parse('')
    assert_empty parse("no configuration file provided\n")
  end

  # Everything before the marker is the polling loop's own noise.
  def test_output_before_the_marker_is_discarded
    assert_equal ['web'], LuxDeploy::Commands.parse_compose_ps("some warning\n__PS__\n#{ROW}").map { |r| r['Service'] }
  end
end

class ComposeFailuresTest < Minitest::Test
  def failures(*rows) = LuxDeploy::Commands.compose_failures(rows).map(&:last)

  def test_running_and_healthy_passes
    assert_empty failures({ 'Service' => 'web', 'State' => 'running', 'Health' => 'healthy' })
  end

  # An empty Health means the image declares no HEALTHCHECK. Failing on that
  # would fail every stock image.
  def test_running_without_a_healthcheck_passes
    assert_empty failures({ 'Service' => 'web', 'State' => 'running', 'Health' => '' })
  end

  def test_an_unhealthy_container_fails
    assert_equal ['db is unhealthy'],
                 failures({ 'Service' => 'db', 'State' => 'running', 'Health' => 'unhealthy' })
  end

  # This is the whole point: compose is active, the web port is bound, and the
  # database behind it is dead.
  def test_a_dead_dependency_fails_while_the_web_container_is_fine
    assert_equal ['db is restarting'],
                 failures({ 'Service' => 'web', 'State' => 'running', 'Health' => 'healthy' },
                          { 'Service' => 'db',  'State' => 'restarting', 'Health' => '' })
  end

  # A one-shot migration container is supposed to be gone by now.
  def test_a_clean_exit_passes_and_a_dirty_one_does_not
    assert_empty failures({ 'Service' => 'migrate', 'State' => 'exited', 'ExitCode' => 0 })
    assert_equal ['migrate exited 1'],
                 failures({ 'Service' => 'migrate', 'State' => 'exited', 'ExitCode' => 1 })
  end

  def test_created_and_lowercase_keys
    assert_equal ['web is created'], failures({ 'Service' => 'web', 'State' => 'created' })
    assert_equal ['web exited 2'],   failures({ 'Name' => 'web', 'state' => 'exited', 'exitCode' => 2 })
  end
end
