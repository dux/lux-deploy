require_relative 'test_helper'

class TemplateTest < Minitest::Test
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
