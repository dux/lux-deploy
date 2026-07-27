require 'io/console'

module LuxDeploy
  # Live view of one host: every app, every unit, what is actually running.
  #
  # Talks over the same ssh connection every other command uses - no agent, no
  # listening port, no second credential. ControlMaster makes a refresh a
  # round trip on an open socket, so polling is cheap enough to be automatic.
  class Tui
    REFRESH ||= 5     # seconds between automatic gathers
    TICK    ||= 0.25  # input poll, also the redraw rate

    RESET  ||= "\e[0m"
    DIM    ||= "\e[2m"
    BOLD   ||= "\e[1m"
    RED    ||= "\e[31m"
    GREEN  ||= "\e[32m"
    YELLOW ||= "\e[33m"
    INVERT ||= "\e[7m"

    CTRL_C ||= "\u0003".freeze

    HELP ||= '↑↓ select   ⏎ logs   r restart   s stop   S start   g refresh   q quit'.freeze

    def initialize(ssh, config)
      @ssh    = ssh
      @config = config
      @cursor = 0
      @status = nil
    end

    def run
      @ssh.quiet = true # its command echo goes to stderr, i.e. onto this screen
      refresh!
      $stdin.raw!
      print "\e[?25l" # hide cursor
      loop do
        refresh! if Time.now - @fetched_at > REFRESH
        draw
        break unless handle(read_key)
      end
    ensure
      @ssh.quiet = false
      $stdin.cooked!
      print "\e[?25h\e[2J\e[H"
    end

    private

    def refresh!
      @apps, @ports = HostState.gather(@ssh, @config)
      @rows         = build_rows
      @cursor       = @cursor.clamp(0, [@rows.size - 1, 0].max)
      @fetched_at   = Time.now
    end

    # One row per unit, with its app carried alongside so the table can repeat
    # the app columns only on its first line.
    def build_rows
      @apps.flat_map do |app|
        app.units.each_with_index.map { |unit, i| { app: app, unit: unit, first: i.zero? } }
      end
    end

    def selected = @rows[@cursor]

    # ---------------------------------------------------------------- input

    def read_key
      return nil unless IO.select([$stdin], nil, nil, TICK)
      c = $stdin.getc
      return c unless c == "\e"
      # Arrow keys arrive as ESC [ A. Nothing follows a bare ESC, so do not block.
      return :esc unless IO.select([$stdin], nil, nil, 0.02)
      $stdin.getc
      case $stdin.getc
      when 'A' then :up
      when 'B' then :down
      else :esc
      end
    end

    # Returns false to quit.
    def handle(key)
      case key
      when nil          then true
      when 'q', CTRL_C  then false
      when :up,   'k'   then move(-1)
      when :down, 'j'   then move(1)
      when 'g'          then (refresh!; true)
      when "\r", "\n"   then logs
      when 'r'          then unit_action('restart')
      when 's'          then unit_action('stop')
      when 'S'          then unit_action('start')
      else true
      end
    end

    def move(step)
      @cursor = (@cursor + step).clamp(0, [@rows.size - 1, 0].max)
      true
    end

    # ---------------------------------------------------------------- actions

    # Hand the terminal back for the duration - journalctl -f wants a real tty,
    # and the alternative is reimplementing a pager.
    def logs
      row = selected or return true
      $stdin.cooked!
      print "\e[?25h\e[2J\e[H"
      system('ssh', '-t', "root@#{@ssh.host}", "journalctl -fu #{row[:unit].name} -n 200")
      $stdin.raw!
      print "\e[?25l"
      true
    end

    def unit_action(verb)
      row = selected or return true
      unit = row[:unit].name
      return true unless confirm("#{verb} #{unit}?")

      out = @ssh.run("systemctl #{verb} #{Shellwords.escape(unit)} 2>&1 || true", allow_fail: true)
      @status = out.to_s.strip.empty? ? "#{verb} #{unit}: ok" : "#{verb} #{unit}: #{out.lines.first.to_s.strip}"
      # systemd needs a beat before is-active reports the new state.
      sleep 0.6
      refresh!
      true
    end

    def confirm(question)
      @status = "#{question}  [y/N]"
      draw
      loop do
        key = read_key
        next if key.nil?
        @status = nil
        return key == 'y'
      end
    end

    # ---------------------------------------------------------------- drawing

    def draw
      rows, cols = IO.console.winsize
      out = +"\e[H\e[2J"
      out << header(cols) << "\n"
      out << rule(cols) << "\n"
      out << table_head(cols) << "\n"

      # Clamped: a window shorter than the chrome would otherwise compute a
      # negative body and silently render nothing at all.
      body = [rows - 6, 1].max
      window(body).each { |i| out << line(@rows[i], i == @cursor, cols) << "\n" }

      out << rule(cols) << "\n"
      out << (@status ? "#{YELLOW}#{@status}#{RESET}" : "#{DIM}#{HELP}#{RESET}")
      print out
    end

    # Scroll only when the cursor would leave the visible slice.
    def window(height)
      return (0...@rows.size) if @rows.size <= height
      top = [[@cursor - height / 2, 0].max, @rows.size - height].min
      (top...top + height)
    end

    def header(cols)
      age  = Time.now - @fetched_at
      left = "#{BOLD}lux-deploy#{RESET}  #{@ssh.host}"
      right = "#{DIM}refreshed #{age.round}s ago#{RESET}"
      pad = cols - visible(left).length - visible(right).length
      left + (' ' * [pad, 1].max) + right
    end

    def rule(cols) = "#{DIM}#{'─' * cols}#{RESET}"

    def table_head(cols)
      "#{DIM}#{row_text({ app: 'APP', branch: 'BRANCH', commit: 'COMMIT', unit: 'UNIT',
                          state: 'STATE', rst: 'RST', port: 'PORT' }, cols)}#{RESET}"
    end

    def line(row, active, cols)
      app, unit = row[:app], row[:unit]
      first = row[:first]

      state = unit.missing? ? 'MISSING' : unit.state
      rst   = unit.restarts.zero? ? '0' : humanize(unit.restarts)
      port  = first ? port_cell(app) : ''

      text = row_text({ app:    first ? app.name + (app.legacy ? ' *' : '') : '',
                        branch: first ? app.branch : '',
                        commit: first ? app.commit : '',
                        unit:   unit.name, state: state, rst: rst, port: port }, cols)

      # Combined, not either/or: selecting a crash-looping row must not paint
      # over the one signal that made you select it.
      colour = "#{active ? INVERT : ''}#{unit.healthy? ? '' : RED}"
      "#{colour}#{text}#{RESET}"
    end

    def port_cell(app)
      return '-' if app.ports.empty?
      app.ports.map { |p| @ports.include?(p) ? "#{p} ●" : "#{p} ○" }.join(' ')
    end

    def humanize(n) = n < 1000 ? n.to_s : "#{(n / 1000.0).round}k"

    # UNIT / STATE / RST / PORT are the reason this view exists and always
    # render. APP / BRANCH / COMMIT are context, and get dropped - rightmost
    # first - when the window cannot hold them. A fixed layout put the context
    # first, so at 80 columns the useful half fell off the edge.
    FIXED    ||= 46 # leading space + unit(26) + state(11) + rst(5) + separators
    OPTIONAL ||= [[:app, 20], [:branch, 7], [:commit, 8]].freeze

    def layout(cols)
      used = FIXED
      OPTIONAL.take_while { |_, w| (used += w + 1) <= cols }
    end

    def row_text(cells, cols)
      parts = layout(cols).map { |key, w| clip(cells[key], w) }
      parts << clip(cells[:unit], 26) << clip(cells[:state], 11) << cells[:rst].to_s.rjust(5)
      clip(" #{parts.join(' ')}  #{cells[:port]}", cols)
    end

    def clip(str, width)
      s = str.to_s
      s.length <= width ? s.ljust(width) : "#{s[0, width - 1]}…"
    end

    def visible(str) = str.gsub(/\e\[[0-9;]*m/, '')
  end
end
