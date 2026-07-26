require_relative 'test_helper'

class ManifestTest < Minitest::Test
  def redact(env) = LuxDeploy::Manifest.env_section(env)

  def test_key_patterns_are_redacted_by_substring
    out = redact(SECRET: 's', JWT_SECRET: 's', DB_URL: 'u', DATABASE_URL: 'u',
                 MY_API_TOKEN: 't', AWS_ACCESS_KEY_ID: 'k', PASSWORD: 'p',
                 DB_MAIN: 'm', CREDENTIAL_FILE: 'c')

    out.each { |k, v| assert_equal '<redacted>', v, "#{k} should be redacted" }
  end

  def test_ordinary_keys_survive
    out = redact(RACK_ENV: 'production', DOMAIN: 'a.com', PORT: '3010')

    assert_equal({ RACK_ENV: 'production', DOMAIN: 'a.com', PORT: '3010' }, out)
  end

  # Backstop for a credential-carrying value under an innocuous key name.
  def test_url_embedded_credentials_are_redacted_regardless_of_key
    assert_equal '<redacted>', redact(STORE: 'postgres://user:pass@host/db')[:STORE]
    assert_equal '<redacted>', redact(CACHE: 'redis://:pass@host')[:CACHE]
    assert_equal 'https://a.com/x', redact(SITE: 'https://a.com/x')[:SITE]
  end

  def test_extract_directive_returns_nil_when_absent
    unit = "[Service]\nExecStart=/usr/bin/app -p 3010\n"

    assert_equal '/usr/bin/app -p 3010', LuxDeploy::Manifest.extract_directive(unit, 'ExecStart')
    assert_nil LuxDeploy::Manifest.extract_directive(unit, 'ExecReload')
    assert_nil LuxDeploy::Manifest.extract_directive(nil, 'ExecStart')
  end
end
