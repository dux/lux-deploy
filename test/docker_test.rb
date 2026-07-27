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
end
