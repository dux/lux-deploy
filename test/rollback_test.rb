require_relative 'test_helper'

class RollbackTest < Minitest::Test
  def unit(name)
    LuxDeploy::Context::Service.new(name, nil, "systemd.#{name}.service", "web-a.com-#{name}", false)
  end

  def test_a_unit_the_restored_release_lacks_is_stale
    stale = LuxDeploy::Commands.stale_units([unit('web'), unit('job')], [unit('web')])

    assert_equal ['web-a.com-job'], stale.map(&:unit)
  end

  def test_nothing_is_stale_when_the_sets_match
    assert_empty LuxDeploy::Commands.stale_units([unit('web')], [unit('web')])
  end

  # `up` on the on_fail path passes the units *this* deploy installed, because
  # the manifest on the box is still the previous deploy's - without that, a
  # service introduced by the failed deploy keeps running after the rollback.
  def test_a_unit_added_by_the_failed_deploy_is_torn_down
    installed = [unit('web'), unit('job')] # what `up` just started
    restored  = [unit('web')]              # what the previous release had

    assert_equal ['web-a.com-job'], LuxDeploy::Commands.stale_units(installed, restored).map(&:unit)
  end

  def test_a_unit_only_the_restored_release_has_is_not_stale
    assert_empty LuxDeploy::Commands.stale_units([unit('web')], [unit('web'), unit('job')])
  end
end
