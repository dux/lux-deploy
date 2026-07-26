require_relative 'test_helper'

# Context building touches git and config/deploy but never the network, so
# everything below runs against a throwaway repo.
class ContextTest < Minitest::Test
  include ProjectFixture

  YAML_MIN = "server: srv.example.com\ndomain: example.com\n".freeze

  def in_app(files = {}, branch: 'main', &block)
    in_project({ '.yaml' => YAML_MIN, '.env' => '', 'caddy.conf' => '',
                 'systemd.service' => '' }.merge(files)) do
      git_repo(branch)
      block.call(LuxDeploy::Context.build({}))
    end
  end

  # `git rev-parse --abbrev-ref HEAD` reports "HEAD" until the first commit
  # exists, so the fixture has to make one for the branch to be visible.
  def git_repo(branch)
    env = { 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
            'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' }
    quiet = { out: File::NULL, err: File::NULL }
    system('git', 'init', '--quiet', '--initial-branch', branch, quiet)
    system(env, 'git', 'commit', '--quiet', '--allow-empty', '-m', 'init', quiet)
  end

  def test_web_service_plus_one_extra_unit
    in_app({ 'job.service' => '' }) do |ctx|
      assert_equal %w[web job], ctx.services.map(&:name)
      assert_equal %w[web-example.com web-example.com-job], ctx.services.map(&:unit)
      assert_equal %w[systemd.service systemd.job.service], ctx.services.map(&:artifact)
    end
  end

  def test_bang_prefixed_service_files_are_ignored
    in_app({ 'job.service' => '', '!scratch.service' => '' }) do |ctx|
      assert_equal %w[web job], ctx.services.map(&:name)
    end
  end

  def test_app_slug_strips_a_wildcard_and_takes_the_first_domain
    in_project({ '.yaml' => "server: s\ndomain: '*.example.com, example.org'\n" }) do
      git_repo('main')
      ctx = LuxDeploy::Context.build({})

      assert_equal 'example.com', ctx.app
      assert_equal '/home/deployer/apps/example.com', ctx.app_dir
    end
  end

  def test_env_template_falls_back_to_main_or_staging
    in_app({}, branch: 'main')    { |ctx| assert_equal '.env',         ctx.env_template_name }
    in_app({}, branch: 'topic')   { |ctx| assert_equal '.env.staging', ctx.env_template_name }
  end

  def test_a_per_branch_env_template_wins
    in_app({ '.env.topic' => '' }, branch: 'topic') do |ctx|
      assert_equal '.env.topic', ctx.env_template_name
    end
  end

  def test_a_slashed_branch_resolves_to_the_underscored_template
    in_app({ '.env.feature_x' => '' }, branch: 'feature/x') do |ctx|
      assert_equal '.env.feature_x', ctx.env_template_name
    end
  end

  # .env.local is the name of the *server* overlay; a branch called "local"
  # must not turn a local file of that name into the env template.
  def test_env_local_is_never_picked_as_a_branch_template
    in_app({ '.env.local' => '' }, branch: 'local') do |ctx|
      assert_equal '.env.staging', ctx.env_template_name
    end
  end

  def test_a_bad_on_fail_fails_before_any_remote_work
    err = assert_raises(LuxDeploy::Error) do
      in_project({ '.yaml' => "server: s\ndomain: example.com\non_fail: rollbck\n" }) do
        git_repo('main')
        LuxDeploy::Context.build({})
      end
    end

    assert_includes err.message, 'on_fail must be one of'
  end

  def test_ruby_probe_is_gated_on_a_template_referencing_it
    in_app({ 'systemd.service' => 'ExecStart=/srv/app' }) { |ctx| refute ctx.ruby_used? }
    in_app({ 'systemd.service' => 'ExecStart={{RUBY}} -S bundle exec rackup' }) { |ctx| assert ctx.ruby_used? }
  end

  def test_needed_port_keys_unions_env_declarations_and_placeholders
    in_app({ '.env'            => "PORT=\nPORT_JOB=\nDB_URL=x\n",
             'caddy.conf'      => 'reverse_proxy localhost:{{PORT}}',
             'systemd.service' => 'ExecStart=app -p {{PORT_GRPC}}' }) do |ctx|
      assert_equal %i[PORT PORT_JOB PORT_GRPC], LuxDeploy::Commands.needed_port_keys(ctx)
    end
  end

  # The manifest is written by one command and read back by rollback / status /
  # destroy / host:apps, so the round trip has to survive YAML.safe_load - in
  # particular the ISO8601 timestamps, which safe_load rejects if they come
  # back as Time rather than String.
  def test_manifest_round_trips_through_the_reader
    in_app({ 'job.service' => '' }) do |ctx|
      ctx.ports    = { PORT: 3010, PORT_JOB: 3020 }
      ctx.rendered = { '.env' => "DOMAIN=example.com\nSECRET=s3cret\nPORT=3010\n",
                       'caddy.config' => '',
                       'systemd.service' => "[Service]\nExecStart=/srv/app -p 3010\n",
                       'systemd.job.service' => "[Service]\nExecStart=/srv/job\n" }

      man = LuxDeploy::RemoteState.parse(LuxDeploy::Manifest.render(ctx))

      refute_nil man
      assert_equal 'example.com', man['app']
      assert_equal 'main',        man.dig('git', 'branch')
      assert_kind_of String,      man['deployed_at']
      assert_equal '<redacted>',  man.dig('env', 'SECRET')
      assert_equal 'example.com', man.dig('env', 'DOMAIN')

      units = LuxDeploy::RemoteState.manifest_services(man)
      assert_equal %w[web-example.com web-example.com-job], units.map(&:unit)
      assert_equal %w[systemd.service systemd.job.service], units.map(&:artifact)
    end
  end

  def test_a_web_app_gets_a_port_from_caddy_alone
    in_app({ '.env' => "DB_URL=x\n", 'caddy.conf' => 'reverse_proxy localhost:{{PORT}}' }) do |ctx|
      assert_equal [:PORT], LuxDeploy::Commands.needed_port_keys(ctx)
    end
  end
end
