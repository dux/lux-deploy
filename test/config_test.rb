require_relative 'test_helper'

class ConfigTest < Minitest::Test
  include ProjectFixture

  def test_src_file_overrides_yaml
    in_project('src' => "./tmp/app-packed\n") do
      assert_equal './tmp/app-packed/', LuxDeploy::Config.new('src' => './tmp/legacy-pack').src
    end
  end

  def test_blank_src_file_falls_back_to_yaml
    in_project('src' => "\n") do
      assert_equal './tmp/legacy-pack/', LuxDeploy::Config.new('src' => './tmp/legacy-pack').src
    end
  end

  def test_src_defaults_to_project_root
    in_project do
      assert_equal './', LuxDeploy::Config.new({}).src
    end
  end

  def test_yaml_wins_over_plugin_defaults_wins_over_engine
    LuxDeploy.set_defaults(service_prefix: 'lux-web', remote_base: '/home/deployer/lux-apps')
    config = LuxDeploy::Config.new('service_prefix' => 'mine')

    assert_equal 'mine',                    config.service_prefix
    assert_equal '/home/deployer/lux-apps', config.remote_base
    assert_equal 'deployer',                config.service_user
  ensure
    LuxDeploy.set_defaults({})
  end

  def test_behavioral_keys_stay_out_of_the_placeholder_namespace
    vars = LuxDeploy::Config.new('domain' => 'example.com', 'cdn' => 'cdn.example.com').template_vars

    assert_equal 'example.com',     vars[:DOMAIN]
    assert_equal 'cdn.example.com', vars[:CDN]
    refute vars.key?(:SERVICE_USER)
    refute vars.key?(:REMOTE_BASE)
    refute vars.key?(:ON_FAIL)
  end

  def test_on_fail_defaults_to_keep_and_validates
    refute LuxDeploy::Config.new({}).rollback_on_fail?
    assert LuxDeploy::Config.new('on_fail' => 'rollback').rollback_on_fail?

    err = assert_raises(LuxDeploy::Error) { LuxDeploy::Config.new('on_fail' => 'revert').on_fail }
    assert_includes err.message, 'on_fail must be one of'
  end
end
