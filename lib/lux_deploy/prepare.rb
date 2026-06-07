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
