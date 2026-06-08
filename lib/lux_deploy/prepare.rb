module LuxDeploy
  # Host bootstrap for the reverse proxy. Installs the package, creates the
  # per-site config dir, wires the include/import directive, enables + starts
  # the service. Host setup only - the deploy flow is caddy-fronted and
  # unchanged. Every step is idempotent so re-running is safe. Debian/Ubuntu
  # (apt), matching the rest of the gem's host assumptions.
  module Prepare
    module_function

    def caddy(ssh)
      ssh.stream(<<~SH)
        set -e
        if command -v caddy >/dev/null; then
          echo "caddy already installed: $(caddy version | head -n1)"
        else
          echo "installing caddy from official repo"
          apt-get update
          apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \\
            | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \\
            > /etc/apt/sources.list.d/caddy-stable.list
          apt-get update
          apt-get install -y caddy
        fi

        install -d -m 0755 #{CADDY_SITES}
        if ! grep -Rq 'import #{CADDY_SITES}/\\*.caddy' /etc/caddy/ 2>/dev/null; then
          echo "wiring import into /etc/caddy/Caddyfile"
          printf '\\nimport #{CADDY_SITES}/*.caddy\\n' >> /etc/caddy/Caddyfile
        fi

        systemctl enable --now caddy
        systemctl reload caddy || systemctl restart caddy
      SH
    end

    # Install mise for the service user and activate it in the login shell.
    # lux-deploy runs every remote step via `sudo -iu <user> bash -lc`, so the
    # activation must live where a non-interactive login shell sources it.
    # Debian's default .bashrc returns early for non-interactive shells, so we
    # wire .profile (no interactive guard, sourced by `bash -lc`) instead.
    def mise(ssh)
      user = ssh.service_user
      ssh.stream(<<~SH)
        set -e
        if sudo -iu #{user} bash -lc 'command -v mise >/dev/null'; then
          echo "mise already installed: $(sudo -iu #{user} bash -lc 'mise version' | head -n1)"
        else
          echo "installing mise for #{user}"
          sudo -iu #{user} bash -lc 'curl -fsSL https://mise.run | sh'
        fi

        rc=/home/#{user}/.profile
        if ! grep -q 'mise activate bash' "$rc" 2>/dev/null; then
          echo "wiring mise activate into $rc"
          printf '\\neval "$(~/.local/bin/mise activate bash)"\\n' | sudo -u #{user} tee -a "$rc" >/dev/null
        fi

        # Prove it resolves in a fresh login shell - the same shape every
        # remote deploy step uses.
        sudo -iu #{user} bash -lc 'mise --version'
      SH
    end

    def nginx(ssh)
      ssh.stream(<<~SH)
        set -e
        if command -v nginx >/dev/null; then
          echo "nginx already installed: $(nginx -v 2>&1)"
        else
          echo "installing nginx"
          apt-get update
          apt-get install -y nginx
        fi

        install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
        if ! grep -q 'include /etc/nginx/sites-enabled/' /etc/nginx/nginx.conf; then
          echo "wiring include into /etc/nginx/nginx.conf http{} block"
          sed -i 's|^\\(\\s*\\)http {|\\1http {\\n    include /etc/nginx/sites-enabled/*;|' /etc/nginx/nginx.conf
        fi

        systemctl enable --now nginx
        nginx -t
        systemctl reload nginx || systemctl restart nginx
      SH
    end
  end
end
