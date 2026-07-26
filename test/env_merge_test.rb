require_relative 'test_helper'

class EnvMergeTest < Minitest::Test
  def merge(body, pairs) = LuxDeploy::Commands.merge_env(body, pairs)

  def test_replaces_an_existing_key_in_place
    assert_equal "A=1\nPORT=3010\nB=2\n",
                 merge("A=1\nPORT=\nB=2\n", PORT: 3010)
  end

  def test_appends_a_missing_key
    assert_equal "A=1\nPORT=3010\n", merge("A=1\n", PORT: 3010)
  end

  def test_appends_a_newline_when_the_body_has_none
    assert_equal "A=1\nPORT=3010\n", merge('A=1', PORT: 3010)
  end

  # The `=` anchor is what keeps a PORT= replacement off PORT_JOB=.
  def test_port_does_not_clobber_a_prefixed_sibling
    merged = merge("PORT_JOB=\nPORT=\n", PORT: 3010, PORT_JOB: 3020)

    assert_equal "PORT_JOB=3020\nPORT=3010\n", merged
  end

  def test_regex_metacharacters_in_a_key_are_literal
    assert_equal "A.B=x\nAXB=keep\n", merge("A.B=\nAXB=keep\n", 'A.B' => 'x')
  end

  def test_later_pairs_win_over_earlier_ones
    body = merge(merge("SECRET=template\n", 'SECRET' => 'overlay'), SECRET: 'engine')

    assert_equal "SECRET=engine\n", body
  end
end
