require_relative 'test_helper'

# doctor's local pass runs before any ssh and has to work in a project that is
# broken - that is the point of it - so it reads the filesystem directly rather
# than going through Context, which raises on a malformed .yaml.
class DoctorLocalTest < Minitest::Test
  include ProjectFixture

  YAML_MIN ||= "server: s\ndomain: example.com\n".freeze
  UNIT ||= "[Service]\nExecStart=/usr/bin/docker compose -f {{COMPOSE_FILE}} up\n".freeze
  COMPOSE ||= "name: {{APP}}\nservices:\n  web:\n    ports: ['127.0.0.1:{{PORT}}:8080']\n".freeze

  # Returns [failures, printed output].
  def check(files)
    in_project({ '.yaml' => YAML_MIN, '.env.main' => '', 'caddy.conf' => '' }.merge(files)) do
      out, = capture_io { @failed = LuxDeploy::Doctor.local_checks(nil) }
      return [@failed, out]
    end
  end

  def test_a_compose_files_placeholders_are_checked_like_any_other
    failed, out = check({ 'systemd.service' => UNIT, 'docker-compose.yaml' => COMPOSE })
    assert_equal 0, failed, out

    failed, out = check({ 'systemd.service' => UNIT,
                          'docker-compose.yaml' => "name: x\nimage: app:{{RELEASE_TAG}}\n" })
    assert_operator failed, :>, 0
    assert_includes out, '{{RELEASE_TAG}}'
  end

  # {{COMPOSE_FILE}} is engine-provided, so a unit may use it without
  # declaring anything in .yaml.
  def test_compose_file_is_a_provided_placeholder
    failed, out = check({ 'systemd.service' => UNIT, 'docker-compose.yaml' => COMPOSE })
    assert_equal 0, failed, out
    refute_includes out, 'COMPOSE_FILE'
  end

  # `docker compose -f <file>` names the project after the file's directory,
  # which on the server is <remote_base>/<domain>/<branch>. Two apps on `main`
  # would share the project, and `compose down` in one reaches the other.
  def test_a_compose_file_without_a_project_name_fails
    failed, out = check({ 'systemd.service' => UNIT,
                          'docker-compose.yaml' => "services:\n  web:\n    image: app\n" })

    assert_operator failed, :>, 0
    assert_includes out, 'sets a compose project name'
    assert_includes out, 'name: {{APP}}'
  end

  # The mode switch is the file existing, but nothing runs it unless a unit
  # says so - without this the deploy is clean and serves nothing.
  def test_a_compose_file_no_unit_runs_fails
    failed, out = check({ 'systemd.service' => "[Service]\nExecStart=/srv/app\n",
                          'docker-compose.yaml' => COMPOSE })

    assert_operator failed, :>, 0
    assert_includes out, 'a *.service runs docker-compose.yaml'
  end

  # systemd.service ships the compose ExecStart commented out. Scanning the
  # whole file would pass every app that never uncommented it.
  def test_a_commented_out_exec_start_does_not_count
    failed, out = check({ 'systemd.service' => "[Service]\n# ExecStart=/usr/bin/docker compose -f {{COMPOSE_FILE}} up\nExecStart=/srv/app\n",
                          'docker-compose.yaml' => COMPOSE })

    assert_operator failed, :>, 0
    assert_includes out, 'a *.service runs docker-compose.yaml'
  end

  def test_an_extra_unit_can_be_the_one_that_runs_it
    failed, out = check({ 'systemd.service' => "[Service]\nExecStart=/srv/app\n",
                          'stack.service'   => UNIT,
                          'docker-compose.yaml' => COMPOSE })

    assert_equal 0, failed, out
  end

  # The file is rendered from the repo and uploaded 0644, same as the units.
  def test_inline_secrets_warn_but_do_not_block
    failed, out = check({ 'systemd.service' => UNIT,
                          'docker-compose.yaml' => "#{COMPOSE}    environment:\n      DB_PASSWORD: hunter2\n" })

    assert_equal 0, failed, out
    assert_includes out, 'WARN'
    assert_includes out, 'no inline secrets'
  end

  def test_none_of_this_fires_for_an_app_without_a_compose_file
    _, out = check({ 'systemd.service' => "[Service]\nExecStart=/srv/app\n" })

    refute_includes out, 'compose'
  end
end
