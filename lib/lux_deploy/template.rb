module LuxDeploy
  # Stupid {{VAR}} substitution. No conditionals, no loops, no escaping.
  # Missing variables raise so we never silently ship a template with
  # an un-rendered placeholder.
  module Template
    module_function

    PLACEHOLDER = /\{\{([A-Z][A-Z0-9_]*)\}\}/

    def render(str, vars)
      norm = vars.transform_keys(&:to_s)
      str.gsub(PLACEHOLDER) do
        key = ::Regexp.last_match(1)
        norm.key?(key) ? norm[key].to_s : raise(Error.new("missing var {{#{key}}}"))
      end
    end

    # Parse a rendered .env file into a symbol-keyed hash. Comments and
    # blank lines are ignored; surrounding single/double quotes are stripped.
    def parse_env(rendered)
      rendered.lines.each_with_object({}) do |line, h|
        next if line.match?(/\A\s*(#|$)/)
        k, v = line.strip.split('=', 2)
        next unless k && v
        h[k.to_sym] = v.gsub(/\A["']|["']\z/, '')
      end
    end

    # KEY => raw right-hand side, kept verbatim (quotes and all). Unlike
    # parse_env this is for values headed back into a .env file, where
    # stripping the quotes would change what the app reads.
    def parse_env_raw(body)
      body.to_s.lines.each_with_object({}) do |line, h|
        next if line.match?(/\A\s*(#|$)/)
        k, v = line.chomp.split('=', 2)
        next unless v && k.to_s.strip.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        h[k.strip] = v
      end
    end

    # DNS-safe form of a branch name - it ends up in a hostname, a systemd
    # unit name and a directory name, so anything outside [a-z0-9-] collapses
    # to a single dash. feature/Login-42 -> feature-login-42
    def slug(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    end

    # Git-derived placeholders, computed locally before any rendering.
    def git_vars
      branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      raise Error.new('not in a git repo (no current branch)') if branch.empty?
      {
        GIT_BRANCH:            branch,
        GIT_BRANCH_UNDERSCORE: branch.gsub(/[^A-Za-z0-9]+/, '_'),
        GIT_BRANCH_SLUG:       slug(branch),
        # Deliberately not memoized: the test suite builds contexts in several
        # throwaway repos in one process, and a cached sha would leak between
        # them. A handful of rev-parses per run is not worth the trap.
        GIT_COMMIT:            `git rev-parse HEAD 2>/dev/null`.strip,
        GIT_COMMIT_SHORT:      `git rev-parse --short HEAD 2>/dev/null`.strip
      }
    end
  end
end
