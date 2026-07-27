require_relative 'test_helper'

# The pre-0.3 layout put an app flat at <remote_base>/<domain>/ under unit
# <prefix>-<domain>. `migrate` has to find those names to tear them down, and
# the manifest that shipped with them is the only reliable record.
class LegacyUnitsTest < Minitest::Test
  include ProjectFixture

  YAML_MIN = "server: s\ndomain: example.com\n".freeze

  def in_app(files = {}, &block)
    in_project({ '.yaml' => YAML_MIN, '.env.main' => '', 'caddy.conf' => '',
                 'systemd.service' => '' }.merge(files)) do
      quiet = { out: File::NULL, err: File::NULL }
      system('git', 'init', '--quiet', '--initial-branch', 'main', quiet)
      system({ 'GIT_AUTHOR_NAME' => 't', 'GIT_AUTHOR_EMAIL' => 't@t',
               'GIT_COMMITTER_NAME' => 't', 'GIT_COMMITTER_EMAIL' => 't@t' },
             'git', 'commit', '--quiet', '--allow-empty', '-m', 'init', quiet)
      block.call(LuxDeploy::Context.build({}))
    end
  end

  # Stub the remote read so the fallback path is exercised without ssh.
  def with_manifest(ctx, body)
    ctx.define_singleton_method(:ssh) { Struct.new(:dry_run).new(false) }
    LuxDeploy::RemoteState.define_singleton_method(:read_manifest) { |_c, dir: nil| body }
    yield
  ensure
    LuxDeploy::RemoteState.singleton_class.remove_method(:read_manifest)
  end

  def test_units_come_from_the_legacy_manifest_when_there_is_one
    in_app do |ctx|
      manifest = { 'services' => {
        'web' => { 'unit' => 'web-example.com.service',     'source' => '/apps/example.com/systemd.service' },
        'job' => { 'unit' => 'web-example.com-job.service', 'source' => '/apps/example.com/systemd.job.service' }
      } }

      with_manifest(ctx, manifest) do
        assert_equal %w[web-example.com web-example.com-job], LuxDeploy::Commands.legacy_units(ctx)
      end
    end
  end

  # An app deployed before manifests existed still has to be torn down, so the
  # names are rebuilt from the checkout - note they use the bare domain, not
  # the 0.3 <domain>-<branch> slug.
  def test_units_fall_back_to_the_checkout_without_a_manifest
    in_app({ 'job.service' => '' }) do |ctx|
      with_manifest(ctx, nil) do
        assert_equal %w[web-example.com web-example.com-job], LuxDeploy::Commands.legacy_units(ctx)
      end
    end
  end

  # The manifest moves with the payload still naming the pre-0.3 units, so
  # status/destroy/rollback would act on units that no longer exist.
  def test_migrate_repoints_the_manifest_at_the_new_unit_names
    in_app({ 'job.service' => '' }) do |ctx|
      manifest = { 'services' => {
        'web' => { 'unit' => 'web-example.com.service',     'source' => '/apps/example.com/systemd.service' },
        'job' => { 'unit' => 'web-example.com-job.service', 'source' => '/apps/example.com/systemd.job.service' }
      } }
      written = nil
      LuxDeploy::Commands.define_singleton_method(:write_remote_file) { |_c, _p, body, **| written = body }

      with_manifest(ctx, manifest) { capture_io { LuxDeploy::Commands.rename_manifest_units(ctx) } }

      units = YAML.safe_load(written)['services']
      assert_equal 'web-example.com-main.service',     units['web']['unit']
      assert_equal 'web-example.com-main-job.service', units['job']['unit']
      # source is a record of what rendered it, not a live path - leave it be
      assert_equal '/apps/example.com/systemd.service', units['web']['source']
    ensure
      LuxDeploy::Commands.singleton_class.remove_method(:write_remote_file)
    end
  end

  # vibe's case: a job unit was installed by an older deploy, its *.service file
  # has since been deleted locally, and migrate just tore the unit down. Keeping
  # it in the manifest leaves status reporting MISSING forever.
  def test_migrate_drops_units_that_will_never_come_back
    in_app do |ctx|
      manifest = { 'services' => {
        'web' => { 'unit' => 'web-example.com.service',     'source' => '/apps/example.com/systemd.service' },
        'job' => { 'unit' => 'web-example.com-job.service', 'source' => '/apps/example.com/systemd.job.service' }
      } }
      written = nil
      LuxDeploy::Commands.define_singleton_method(:write_remote_file) { |_c, _p, body, **| written = body }

      with_manifest(ctx, manifest) { capture_io { LuxDeploy::Commands.rename_manifest_units(ctx) } }

      units = YAML.safe_load(written)['services']
      assert_equal %w[web], units.keys
      assert_equal 'web-example.com-main.service', units['web']['unit']
    ensure
      LuxDeploy::Commands.singleton_class.remove_method(:write_remote_file)
    end
  end

  # Nothing to rewrite must not mean writing an empty manifest over a good one.
  def test_migrate_leaves_an_unreadable_manifest_alone
    in_app do |ctx|
      called = false
      LuxDeploy::Commands.define_singleton_method(:write_remote_file) { |*| called = true }
      with_manifest(ctx, nil) { LuxDeploy::Commands.rename_manifest_units(ctx) }
      refute called
    ensure
      LuxDeploy::Commands.singleton_class.remove_method(:write_remote_file)
    end
  end

  # The whole point: the legacy names must differ from what 0.3 installs, or
  # migrate would disable the unit it is about to create.
  def test_legacy_names_differ_from_the_branch_layout
    in_app do |ctx|
      with_manifest(ctx, nil) do
        assert_equal ['web-example.com'],      LuxDeploy::Commands.legacy_units(ctx)
        assert_equal ['web-example.com-main'], ctx.services.map(&:unit)
      end
    end
  end
end
