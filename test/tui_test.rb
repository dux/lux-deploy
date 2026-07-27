require_relative 'test_helper'
require 'stringio'

# The render loop needs a terminal, so it is easy to ship untested and find out
# it raises on an empty host or a narrow window. These drive #draw directly with
# a fake console instead.
class TuiRenderTest < Minitest::Test
  Unit ||= LuxDeploy::HostState::Unit
  App  ||= LuxDeploy::HostState::App

  def console(rows: 24, cols: 100)
    Struct.new(:winsize).new([rows, cols])
  end

  def tui(apps, ports: %w[3010], size: { rows: 24, cols: 100 }, cursor: 0, status: nil)
    t = LuxDeploy::Tui.new(Struct.new(:host).new('deb1'), LuxDeploy::Config.new({}))
    t.instance_variable_set(:@apps, apps)
    t.instance_variable_set(:@ports, ports.to_set)
    t.instance_variable_set(:@rows, t.send(:build_rows))
    t.instance_variable_set(:@cursor, cursor)
    t.instance_variable_set(:@status, status)
    t.instance_variable_set(:@fetched_at, Time.now)

    fake = console(**size)
    IO.singleton_class.alias_method(:console_orig, :console)
    IO.singleton_class.define_method(:console) { fake }
    out = StringIO.new
    begin
      $stdout = out
      t.send(:draw)
    ensure
      $stdout = STDOUT
      IO.singleton_class.alias_method(:console, :console_orig)
    end
    out.string
  end

  def app(name, units, ports: %w[3010], legacy: false)
    App.new(name, 'main', 'abc1234', "https://#{name}", ports, units, '', '', legacy)
  end

  def test_a_healthy_host_renders
    out = tui([app('vibe', [Unit.new('web-vibe', 'active', 0)])])

    assert_includes out, 'vibe'
    assert_includes out, 'web-vibe'
    assert_includes out, 'deb1'
    assert_includes out, '3010'
  end

  # The whole reason the TUI exists - it has to be impossible to miss.
  def test_a_crash_looping_unit_renders_in_red_and_abbreviated
    out = tui([app('authcog', [Unit.new('web-authcog', 'active', 0),
                               Unit.new('web-authcog-job', 'activating', 691_459)])])

    assert_includes out, '691k'
    assert_includes out, LuxDeploy::Tui::RED
  end

  def test_a_port_nothing_listens_on_is_marked
    listening = tui([app('a', [Unit.new('web-a', 'active', 0)], ports: %w[3010])], ports: %w[3010])
    silent    = tui([app('a', [Unit.new('web-a', 'active', 0)], ports: %w[3999])], ports: %w[3010])

    assert_includes listening, '3010 ●'
    assert_includes silent,    '3999 ○'
  end

  def test_the_legacy_marker_shows
    assert_includes tui([app('old', [Unit.new('web-old', 'active', 0)], legacy: true)]), 'old *'
  end

  def test_an_empty_host_does_not_raise
    assert_includes tui([]), 'deb1'
  end

  # A window shorter than the chrome computes a negative body height, which
  # renders nothing at all rather than raising - so assert a row is still there.
  def test_a_tiny_window_still_renders_the_selected_row
    out = tui([app('a', [Unit.new('web-a', 'active', 0)])], size: { rows: 4, cols: 60 })
    assert_includes out, 'web-a'
  end

  # A fixed layout put APP/BRANCH/COMMIT first, so at 80 columns the unit, its
  # state and its restart count - the entire point of the view - fell off the
  # right edge. Context columns must be the ones that go.
  def test_the_unit_and_state_survive_a_narrow_window
    units = [Unit.new('web-authcog-job', 'activating', 691_459)]
    out   = tui([app('authcog', units)], size: { rows: 24, cols: 80 })

    assert_includes out, 'web-authcog-job'
    assert_includes out, 'activating'
    assert_includes out, '691k'
  end

  # Widest context column goes first; the narrowest survives longest.
  def test_context_columns_drop_rightmost_first
    units = [Unit.new('web-a', 'active', 0)]
    wide  = tui([app('a', units)], size: { rows: 24, cols: 120 })
    mid   = tui([app('a', units)], size: { rows: 24, cols: 80 })

    assert_includes wide, 'COMMIT'
    refute_includes mid,  'COMMIT'
    assert_includes mid,  'APP'
  end

  # More units than fit: the selected row has to stay on screen.
  def test_the_window_scrolls_to_keep_the_cursor_visible
    units = (1..40).map { |i| Unit.new(format('web-%02d', i), 'active', 0) }
    out   = tui([app('big', units)], size: { rows: 20, cols: 100 }, cursor: 38)

    assert_includes out, 'web-39'
    refute_includes out, 'web-01'
  end

  # Selecting the broken row is the first thing you do; it must stay red.
  def test_selection_does_not_hide_the_unhealthy_colour
    units = [Unit.new('web-a-job', 'activating', 500)]
    out   = tui([app('a', units)], cursor: 0)

    assert_includes out, LuxDeploy::Tui::INVERT
    assert_includes out, LuxDeploy::Tui::RED
  end

  def test_the_status_line_replaces_the_help_line
    out = tui([app('a', [Unit.new('web-a', 'active', 0)])], status: 'restart web-a?  [y/N]')

    assert_includes out, 'restart web-a?'
    refute_includes out, 'q quit'
  end
end

# SSH echoes every command to stderr, which shares the terminal the TUI draws
# on - each refresh used to scribble over the screen.
class TuiQuietTest < Minitest::Test
  # dry_run so this never touches the network - the echo happens before the
  # early return, which is exactly the code under test.
  def ssh = LuxDeploy::SSH.new('example.com', dry_run: true)

  def test_the_command_echo_is_on_by_default
    _, err = capture_io { ssh.run('true') }
    assert_includes err, 'true'
  end

  def test_quiet_silences_it
    s = ssh
    s.quiet = true
    _, err = capture_io { s.run('true') }
    assert_empty err
  end
end
