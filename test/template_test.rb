require_relative 'test_helper'

class TemplateTest < Minitest::Test
  include ProjectFixture

  # The commit vars exist so a container image can be tagged with the commit
  # being deployed. The unit file is snapshotted into release/.lux-deploy and
  # restored by rollback, so a sha baked into it rolls back with the release.
  def test_git_vars_expose_the_deployed_commit
    in_project do
      quiet = { out: File::NULL, err: File::NULL }
      system('git', 'init', '--quiet', '--initial-branch', 'main', quiet)
      system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
               'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
             'git', 'commit', '--quiet', '--allow-empty', '-m', 'init', quiet)
      sha = `git rev-parse HEAD`.strip
      vars = LuxDeploy::Template.git_vars

      assert_equal sha,            vars[:GIT_COMMIT]
      assert_equal sha[0, 7],      vars[:GIT_COMMIT_SHORT][0, 7]
      assert_equal 'main',         vars[:GIT_BRANCH]
      assert LuxDeploy::Doctor::PROVIDED_VARS.include?('GIT_COMMIT_SHORT'),
             'doctor must know the var, or it warns about an unresolved placeholder'
    end
  end

  # Two repos in one process must not share a sha - which is why git_vars is
  # recomputed rather than memoized.
  def test_git_vars_are_not_cached_between_repos
    seen = []
    2.times do |i|
      in_project do
        quiet = { out: File::NULL, err: File::NULL }
        system('git', 'init', '--quiet', '--initial-branch', 'main', quiet)
        system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
                 'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
               'git', 'commit', '--quiet', '--allow-empty', '-m', "init #{i}", quiet)
        seen << LuxDeploy::Template.git_vars[:GIT_COMMIT]
      end
    end
    refute_equal seen[0], seen[1]
    refute seen.any?(&:empty?)
  end

  def test_render_substitutes_and_accepts_symbol_or_string_keys
    assert_equal 'a.com:3010',
                 LuxDeploy::Template.render('{{DOMAIN}}:{{PORT}}', DOMAIN: 'a.com', 'PORT' => 3010)
  end

  def test_render_raises_on_an_unknown_placeholder
    err = assert_raises(LuxDeploy::Error) { LuxDeploy::Template.render('x {{NOPE}}', DOMAIN: 'a') }
    assert_includes err.message, '{{NOPE}}'
  end

  def test_render_ignores_non_placeholder_braces
    assert_equal 'caddy { reverse_proxy }',
                 LuxDeploy::Template.render('caddy { reverse_proxy }', {})
  end

  def test_parse_env_strips_quotes_and_skips_comments
    env = LuxDeploy::Template.parse_env(<<~ENV)
      # a comment

      RACK_ENV=production
      DOMAIN="a.com, *.b"
      DB_URL='postgres:///x'
      GREETING=hello=world
      not a pair
    ENV

    assert_equal 'production',      env[:RACK_ENV]
    assert_equal 'a.com, *.b',      env[:DOMAIN]
    assert_equal 'postgres:///x',   env[:DB_URL]
    assert_equal 'hello=world',     env[:GREETING]
  end

  # One pass, one var set: the compose file gets exactly what the units get,
  # and {{COMPOSE_FILE}} only exists once there is a compose file to name.
  def test_render_artifacts_covers_the_compose_file
    ssh = Class.new do
      def dry_run = false
      def run(*, **) = ''
    end.new

    in_project({ '.yaml' => "server: s\ndomain: example.com\n", '.env.main' => "PORT=\n",
                 'caddy.conf' => 'reverse_proxy :{{PORT}}',
                 'systemd.service' => 'ExecStart=/usr/bin/docker compose -f {{COMPOSE_FILE}} up',
                 'docker-compose.yaml' => "name: {{APP}}\nports: ['127.0.0.1:{{PORT}}:8080']\n" }) do
      quiet = { out: File::NULL, err: File::NULL }
      system('git', 'init', '--quiet', '--initial-branch', 'main', quiet)
      system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
               'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
             'git', 'commit', '--quiet', '--allow-empty', '-m', 'init', quiet)

      ctx = LuxDeploy::Context.build({})
      ctx.instance_variable_set(:@ssh, ssh)
      ctx.ports = { PORT: 3010 }
      capture_io { LuxDeploy::Commands.render_artifacts(ctx) }

      dir = '/home/deployer/apps/example.com/main'
      assert_equal %w[.env caddy.config systemd.service docker-compose.yaml].sort,
                   ctx.rendered.keys.sort
      assert_equal "name: example.com-main\nports: ['127.0.0.1:3010:8080']\n",
                   ctx.rendered['docker-compose.yaml']
      assert_includes ctx.rendered['systemd.service'], "-f #{dir}/docker-compose.yaml"
      assert_includes ctx.rendered['.env'], 'PORT=3010'
    end
  end

  def test_parse_env_raw_keeps_the_value_verbatim
    raw = LuxDeploy::Template.parse_env_raw(<<~ENV)
      # comment
      DOMAIN="a.com, *.b"
      EMPTY=
      lowercase=ok
      bad key=nope
    ENV

    assert_equal '"a.com, *.b"', raw['DOMAIN']
    assert_equal '',             raw['EMPTY']
    assert_equal 'ok',           raw['lowercase']
    refute raw.key?('bad key')
  end
end
