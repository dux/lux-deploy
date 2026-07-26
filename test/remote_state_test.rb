require_relative 'test_helper'

class RemoteStateTest < Minitest::Test
  MANIFEST = {
    'git' => { 'commit_short' => 'abc1234', 'commit_subject' => 'fix the thing' },
    'services' => {
      'web' => { 'unit' => 'web-a.com.service',     'source' => '/apps/a.com/systemd.service' },
      'job' => { 'unit' => 'web-a.com-job.service', 'source' => '/apps/a.com/systemd.job.service' }
    }
  }.freeze

  def test_services_are_rebuilt_from_the_manifest
    units = LuxDeploy::RemoteState.manifest_services(MANIFEST)

    assert_equal %w[web-a.com web-a.com-job], units.map(&:unit)
    assert_equal %w[systemd.service systemd.job.service], units.map(&:artifact)
    assert_equal [true, false], units.map(&:web)
  end

  def test_a_manifest_without_services_yields_nothing
    assert_empty LuxDeploy::RemoteState.manifest_services(nil)
    assert_empty LuxDeploy::RemoteState.manifest_services({})
    assert_empty LuxDeploy::RemoteState.manifest_services('services' => { 'web' => 'not a hash' })
  end

  # These readers run against whatever YAML is on the box, so a hand-edited
  # manifest has to fall through to the local scan, never raise.
  def test_readers_survive_a_malformed_manifest
    [{ 'services' => 'oops' },
     { 'services' => %w[a b] },
     { 'services' => nil },
     'not a hash',
     nil].each do |bad|
      assert_empty LuxDeploy::RemoteState.manifest_services(bad), bad.inspect
      assert_equal 'unknown', LuxDeploy::RemoteState.commit(bad), bad.inspect
    end

    assert_equal 'unknown', LuxDeploy::RemoteState.commit('git' => 'oops')
    assert_equal 'unknown', LuxDeploy::RemoteState.commit('git' => {})
    assert_equal '123', LuxDeploy::RemoteState.commit('git' => { 'commit_subject' => 123 })
  end

  def test_incomplete_service_entries_are_skipped
    units = LuxDeploy::RemoteState.manifest_services(
      'services' => { 'web' => { 'unit' => 'web-a', 'source' => '' },
                      'job' => { 'unit' => '', 'source' => '/apps/a/systemd.job.service' } }
    )

    assert_empty units
  end

  def test_parse_tolerates_garbage
    assert_nil LuxDeploy::RemoteState.parse('')
    assert_nil LuxDeploy::RemoteState.parse(nil)
    assert_nil LuxDeploy::RemoteState.parse('just a string')
    assert_nil LuxDeploy::RemoteState.parse("a:\n  - b\n c: broken")
    assert_equal({ 'app' => 'a.com' }, LuxDeploy::RemoteState.parse("app: a.com\n"))
  end

  def test_commit_reads_the_git_section
    assert_equal 'abc1234 fix the thing', LuxDeploy::RemoteState.commit(MANIFEST)
    assert_equal 'unknown', LuxDeploy::RemoteState.commit(nil)
    assert_equal 'abc1234', LuxDeploy::RemoteState.commit('git' => { 'commit_short' => 'abc1234' })
  end
end
