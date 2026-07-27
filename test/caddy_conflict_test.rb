require_relative 'test_helper'

# Caddy adapts every /etc/caddy/sites/*.caddy as one config and rejects the
# whole thing when two files claim one address, so a conflict here is a
# host-wide outage. `up` renders its site file, then refuses if anything else
# already holds one of its addresses.
class CaddyConflictTest < Minitest::Test
  # Minimal stand-in for Context: the check only reads #ssh, #rendered, #app
  # and #host.
  Ctx ||= Struct.new(:ssh, :rendered, :app, :host)
  Ssh ||= Struct.new(:dry_run, :output) do
    def run(_cmd, **_opts) = output
  end

  SITE ||= <<~CADDY
    (sabc12_security_filter) {
      @blocked {
        path *.php
      }
      handle @blocked {
        respond "not found" 404
      }
    }

    http://sohotasks.com, http://*.sohotasks.com {
      import sabc12_security_filter
      reverse_proxy localhost:3030
    }
  CADDY

  def ctx(installed, rendered: SITE, app: 'sohotasks.com-main')
    body = installed.map { |file, text| "__LUX_F__ #{file}\n#{text}" }.join
    Ctx.new(Ssh.new(false, body), { 'caddy.config' => rendered }, app, 'deb1')
  end

  def test_our_own_installed_file_is_not_a_conflict
    c = ctx({ '/etc/caddy/sites/sohotasks.com-main.caddy' => SITE })
    assert_nil LuxDeploy::Commands.check_caddy_conflict!(c)
  end

  def test_an_unrelated_site_is_not_a_conflict
    c = ctx({ '/etc/caddy/sites/vibe.rudex.hr-main.caddy' => "vibe.rudex.hr {\n  respond \"ok\"\n}\n" })
    assert_nil LuxDeploy::Commands.check_caddy_conflict!(c)
  end

  # The case that motivated this: `domain:` was renamed, so the pre-0.3 dir
  # and its site file sit under the OLD name and check_legacy_layout! - which
  # only looks where this app would live now - walks right past them.
  def test_a_stale_file_under_another_name_is_caught
    c = ctx({ '/etc/caddy/sites/soho_tasks.caddy' => SITE })
    err = assert_raises(LuxDeploy::Error) { LuxDeploy::Commands.check_caddy_conflict!(c) }
    assert_includes err.message, '/etc/caddy/sites/soho_tasks.caddy'
    assert_includes err.message, 'http://sohotasks.com'
  end

  # A branch deploy shares the app's parent domain but not its addresses.
  def test_a_branch_site_does_not_collide_with_main
    branch = SITE.sub('http://sohotasks.com, http://*.sohotasks.com',
                      'http://x.sohotasks.com, http://*.x.sohotasks.com')
    c = ctx({ '/etc/caddy/sites/sohotasks.com-main.caddy' => SITE },
            rendered: branch, app: 'sohotasks.com-x')
    assert_nil LuxDeploy::Commands.check_caddy_conflict!(c)
  end

  # Snippets "(name) {", matchers "@name {" and indented directive blocks are
  # not site addresses; treating them as such would fire on every deploy.
  def test_snippets_and_matchers_are_not_addresses
    addresses = LuxDeploy::Commands.site_addresses(SITE)
    assert_equal ['http://sohotasks.com, http://*.sohotasks.com'], addresses
  end

  # A stale file listing only ONE of our addresses still breaks the adapt, so
  # the comparison has to be per-address, not per-line.
  def test_a_partial_overlap_is_caught
    c = ctx({ '/etc/caddy/sites/old.caddy' => "http://*.sohotasks.com {\n  respond \"ok\"\n}\n" })
    err = assert_raises(LuxDeploy::Error) { LuxDeploy::Commands.check_caddy_conflict!(c) }
    assert_includes err.message, 'http://*.sohotasks.com'
    refute_includes err.message, 'http://sohotasks.com,'
  end

  # Real-world shape from /etc/caddy/sites: a port-only address, and a site
  # whose exact hostname sits under another app's wildcard (caddy prefers the
  # specific one, so it is not a conflict).
  def test_specific_host_under_a_wildcard_is_not_a_conflict
    resizer = ":9180 {\n  respond \"ok\"\n}\n\nhttp://resizer.sohotasks.com {\n  respond \"ok\"\n}\n"
    c = ctx({ '/etc/caddy/sites/image-resizer.caddy' => resizer })
    assert_nil LuxDeploy::Commands.check_caddy_conflict!(c)
  end

  # vibe's caddy.conf documents an agent endpoint it deliberately does not
  # publish, in a comment. Reading that as the upstream made `status` report
  # MISMATCH against a healthy deploy.
  def test_commented_out_upstreams_are_not_the_proxy_target
    body = <<~CADDY
      # code.example.com {
      #   reverse_proxy localhost:4096
      # }

      example.com {
        reverse_proxy localhost:3010
      }
    CADDY
    assert_equal 'localhost:3010', LuxDeploy::Commands.proxy_upstream(body)
  end

  def test_dry_run_never_probes_the_host
    c = Ctx.new(Ssh.new(true, 'boom'), { 'caddy.config' => SITE }, 'a', 'h')
    assert_nil LuxDeploy::Commands.check_caddy_conflict!(c)
  end
end
