# Isolated sandbox browser + CDP-only Tailscale gateway.
# Security boundaries:
# 1. Firewall + TCP allowlist: only configured cdpAllowedIps peers + loopback may reach port 18790.
# 2. Bearer token auth (timingSafeEqual) on all CDP HTTP and WebSocket upgrade endpoints (token stays on host).
# 3. Pure CDP proxy: no /exec, no /files, no /mihomo, no desktop/ydotool access.
# 4. Isolated network namespace (pasta --no-map-gw -T none -U none -t none -u none): host 127.0.0.1:9222 is unreachable.
# 5. Isolated Chrome port 9333 + dedicated user-data-dir inside bwrap (--tmpfs $HOME).
# 6. Wayland wp_security_context_manager_v1: Niri blocks sandbox screenshots, clipboard snooping, and virtual input.
{ config, pkgs, lib, privateCfg, ... }:
let
  homeDir = config.home.homeDirectory;
  userName = privateCfg.user.name;
  uidStr = toString privateCfg.user.uid;
  allowedIps =
    [ "127.0.0.1" "::ffff:127.0.0.1" "::1" ]
    ++ lib.concatMap (ip: [ ip "::ffff:${ip}" ]) privateCfg.hosts.thinkpad.tailscale.cdpAllowedIps;
  stateRoot = "${homeDir}/.local/state/muse-browser";
  tokenFileHost = "${homeDir}/.config/muse-browser/token";
  ipcDirHost = "/run/user/${uidStr}/muse-browser-ipc";
  waylandDirHost = "/run/user/${uidStr}/muse-wayland";
  dbusBrokerBin = "${pkgs.dbus-broker}/bin/dbus-broker-launch";
  cdpPort = 9333;

  resolvConfSandbox = pkgs.writeText "muse-browser-resolv.conf" ''
    nameserver 169.254.1.1
  '';

  museWaylandSecCtx = pkgs.runCommandCC "muse-wayland-secctx" {
    nativeBuildInputs = [ pkgs.wayland-scanner pkgs.pkg-config ];
    buildInputs = [ pkgs.wayland ];
  } ''
    mkdir -p $out/bin
    PROTO="${pkgs.wayland-protocols}/share/wayland-protocols/staging/security-context/security-context-v1.xml"
    wayland-scanner client-header "$PROTO" security-context-v1-client-protocol.h
    wayland-scanner private-code "$PROTO" security-context-v1-protocol.c
    cat > main.c << 'EOF'
    #include <errno.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <sys/stat.h>
    #include <sys/un.h>
    #include <unistd.h>
    #include <wayland-client.h>
    #include "security-context-v1-client-protocol.h"

    static struct wp_security_context_manager_v1 *sec_mgr = NULL;
    static const char *g_sock_path = NULL;

    static void on_global(void *data, struct wl_registry *reg, uint32_t name,
                          const char *iface, uint32_t version) {
      (void)data; (void)version;
      if (strcmp(iface, wp_security_context_manager_v1_interface.name) == 0) {
        sec_mgr = wl_registry_bind(reg, name, &wp_security_context_manager_v1_interface, 1);
      }
    }
    static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
      (void)data; (void)reg; (void)name;
    }
    static const struct wl_registry_listener reg_listener = { on_global, on_global_remove };

    static void cleanup_and_exit(int sig) {
      (void)sig;
      if (g_sock_path) unlink(g_sock_path);
      _exit(0);
    }

    int main(int argc, char **argv) {
      if (argc != 2) {
        fprintf(stderr, "Usage: %s <socket-path>\n", argv[0]);
        return 2;
      }
      g_sock_path = argv[1];
      signal(SIGTERM, cleanup_and_exit);
      signal(SIGINT, cleanup_and_exit);

      struct wl_display *display = wl_display_connect(NULL);
      if (!display) {
        perror("wl_display_connect");
        return 1;
      }
      struct wl_registry *reg = wl_display_get_registry(display);
      wl_registry_add_listener(reg, &reg_listener, NULL);
      wl_display_roundtrip(display);
      if (!sec_mgr) {
        fprintf(stderr, "wp_security_context_manager_v1 not advertised by compositor\n");
        return 1;
      }

      int listen_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
      if (listen_fd < 0) { perror("socket"); return 1; }
      struct sockaddr_un addr;
      memset(&addr, 0, sizeof(addr));
      addr.sun_family = AF_UNIX;
      if (strlen(g_sock_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "Socket path too long\n");
        return 1;
      }
      unlink(g_sock_path);
      strncpy(addr.sun_path, g_sock_path, sizeof(addr.sun_path) - 1);
      umask(0077);
      if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
      chmod(g_sock_path, 0600);
      if (listen(listen_fd, 64) < 0) { perror("listen"); return 1; }

      int close_fds[2];
      if (pipe(close_fds) < 0) { perror("pipe"); return 1; }

      struct wp_security_context_v1 *ctx =
        wp_security_context_manager_v1_create_listener(sec_mgr, listen_fd, close_fds[0]);
      wp_security_context_v1_set_sandbox_engine(ctx, "org.flatpak");
      wp_security_context_v1_set_app_id(ctx, "io.muse.browser");
      wp_security_context_v1_set_instance_id(ctx, "muse-browser");
      wp_security_context_v1_commit(ctx);
      wp_security_context_v1_destroy(ctx);
      wp_security_context_manager_v1_destroy(sec_mgr);
      wl_registry_destroy(reg);
      if (wl_display_roundtrip(display) < 0) {
        perror("wl_display_roundtrip");
        return 1;
      }
      close(listen_fd);
      close(close_fds[0]);
      wl_display_disconnect(display);

      for (;;) pause();
      return 0;
    }
    EOF
    $CC -O2 -Wall -Wextra main.c security-context-v1-protocol.c -I. $(pkg-config --cflags --libs wayland-client) -o $out/bin/muse-wayland-secctx
  '';

  sandboxCdpProxyJs = pkgs.writeText "muse-sandbox-cdp-proxy.js" ''
    const net = require("net");
    const http = require("http");
    const fs = require("fs");
    const path = require("path");
    const { spawn } = require("child_process");

    const CDP_PORT = ${toString cdpPort};
    const CDP_SOCK = "/run/user/${uidStr}/ipc/cdp.sock";
    const CTL_SOCK = "/run/user/${uidStr}/ipc/ctl.sock";
    const PROFILE_DIR = "${homeDir}/.local/share/muse-browser";
    const CHROME_BIN = "/run/current-system/sw/bin/google-chrome";

    let chromeChild = null;
    let launchingPromise = null;

    function checkCdpReady() {
      return new Promise((resolve) => {
        const req = http.get({ hostname: "127.0.0.1", port: CDP_PORT, path: "/json/version", timeout: 800 }, (res) => {
          res.resume();
          resolve(res.statusCode === 200);
        });
        req.on("error", () => resolve(false));
        req.on("timeout", () => { req.destroy(); resolve(false); });
      });
    }

    async function ensureChrome(initialUrl) {
      if (await checkCdpReady()) {
        if (initialUrl) {
          await new Promise((resolve) => {
            const req = http.request({
              hostname: "127.0.0.1",
              port: CDP_PORT,
              path: "/json/new?" + encodeURI(initialUrl),
              method: "PUT",
              timeout: 2000
            }, (res) => { res.resume(); resolve(); });
            req.on("error", () => resolve());
            req.on("timeout", () => { req.destroy(); resolve(); });
            req.end();
          });
        }
        return;
      }
      if (!launchingPromise) {
        launchingPromise = (async () => {
          try {
            for (const f of ["SingletonLock", "SingletonCookie", "SingletonSocket"]) {
              try { fs.unlinkSync(path.join(PROFILE_DIR, f)); } catch (_) {}
            }
            const args = [
              "--user-data-dir=" + PROFILE_DIR,
              "--remote-debugging-address=127.0.0.1",
              "--remote-debugging-port=" + CDP_PORT,
              "--ozone-platform=wayland",
              "--password-store=basic",
              "--no-first-run",
              "--no-default-browser-check",
              "--disable-background-networking"
            ];
            if (initialUrl) args.push(initialUrl);
            chromeChild = spawn(CHROME_BIN, args, {
              detached: true,
              stdio: "ignore"
            });
            chromeChild.on("exit", () => { chromeChild = null; });
            chromeChild.unref();

            for (let i = 0; i < 60; i++) {
              if (await checkCdpReady()) return;
              await new Promise((r) => setTimeout(r, 250));
            }
            throw new Error("Timed out waiting for sandbox Chrome CDP on port " + CDP_PORT);
          } finally {
            launchingPromise = null;
          }
        })();
      }
      return launchingPromise;
    }

    const cdpServer = net.createServer(async (client) => {
      try {
        await ensureChrome();
      } catch (err) {
        client.destroy();
        return;
      }
      const upstream = net.createConnection(CDP_PORT, "127.0.0.1");
      const closeBoth = () => {
        client.destroy();
        upstream.destroy();
      };
      client.on("error", closeBoth);
      upstream.on("error", closeBoth);
      client.pipe(upstream);
      upstream.pipe(client);
    });

    try { fs.unlinkSync(CDP_SOCK); } catch (_) {}
    cdpServer.listen(CDP_SOCK, () => {
      fs.chmodSync(CDP_SOCK, 0o600);
      console.log("muse-sandbox-cdp-proxy listening on " + CDP_SOCK);
    });

    const ctlServer = http.createServer(async (req, res) => {
      const u = new URL(req.url, "http://localhost");
      if (req.method === "POST" && u.pathname === "/open") {
        try {
          const targetUrl = u.searchParams.get("url") || "";
          await ensureChrome(targetUrl);
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true }));
        } catch (e) {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: e.message }));
        }
        return;
      }
      if (req.method === "GET" && u.pathname === "/status") {
        const running = await checkCdpReady();
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, chrome_running: running, cdp_port: CDP_PORT }));
        return;
      }
      res.writeHead(404);
      res.end();
    });

    try { fs.unlinkSync(CTL_SOCK); } catch (_) {}
    ctlServer.listen(CTL_SOCK, () => {
      fs.chmodSync(CTL_SOCK, 0o600);
    });
  '';

  museGatewayJs = pkgs.writeText "muse-browser-gateway.js" ''
    process.umask(0o077);
    const net = require("net");
    const http = require("http");
    const fs = require("fs");
    const crypto = require("crypto");

    const PORT = 18790;
    const CDP_PORT = ${toString cdpPort};
    const CDP_SOCK = "${ipcDirHost}/cdp.sock";
    const TOKEN = fs.readFileSync("${tokenFileHost}", "utf8").trim();
    const ALLOWED_IPS = new Set(${builtins.toJSON allowedIps});

    function isAllowedIp(req) {
      const remote = (req.socket && req.socket.remoteAddress) || "";
      return ALLOWED_IPS.has(remote);
    }

    function checkToken(req) {
      const hdr = req.headers["authorization"] || "";
      if (!hdr.startsWith("Bearer ")) return false;
      const got = Buffer.from(hdr.slice(7).trim());
      const exp = Buffer.from(TOKEN);
      return got.length === exp.length && crypto.timingSafeEqual(got, exp);
    }

    function isAllowedCdpHttpPath(pathname) {
      return pathname === "/json" ||
        pathname === "/json/list" ||
        pathname === "/json/version" ||
        pathname === "/json/protocol" ||
        pathname === "/json/new" ||
        /^\/json\/(activate|close)\/[A-Za-z0-9_-]+$/.test(pathname);
    }

    function isAllowedCdpWsPath(pathname) {
      return /^\/devtools\/(browser|page)\/[A-Za-z0-9_-]+$/.test(pathname);
    }

    function sendJson(res, code, obj) {
      if (res.writableEnded) return;
      const body = JSON.stringify(obj);
      res.writeHead(code, {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": Buffer.byteLength(body)
      });
      res.end(body);
    }

    const server = http.createServer((req, res) => {
      if (!isAllowedIp(req)) {
        return sendJson(res, 403, { ok: false, error: "Forbidden peer IP" });
      }
      const u = new URL(req.url, "http://localhost");
      if (req.method === "GET" && u.pathname === "/health") {
        return sendJson(res, 200, {
          ok: true,
          service: "muse-browser-cdp",
          mode: "sandbox-cdp-only",
          cdp_port: CDP_PORT
        });
      }
      if (!checkToken(req)) {
        return sendJson(res, 401, { ok: false, error: "Unauthorized" });
      }
      if (!isAllowedCdpHttpPath(u.pathname)) {
        return sendJson(res, 404, { ok: false, error: "Only CDP endpoints are exposed" });
      }

      const publicHost = req.headers["host"] || ("127.0.0.1:" + PORT);
      const upReq = http.request({
        socketPath: CDP_SOCK,
        path: u.pathname + u.search,
        method: req.method,
        headers: {
          "Host": "127.0.0.1:" + CDP_PORT
        }
      }, (upRes) => {
        const chunks = [];
        upRes.on("data", (c) => chunks.push(c));
        upRes.on("end", () => {
          const rawBody = Buffer.concat(chunks).toString("utf8");
          const rewritten = rawBody
            .replaceAll("127.0.0.1:" + CDP_PORT, publicHost)
            .replaceAll("localhost:" + CDP_PORT, publicHost);
          const headers = { ...upRes.headers };
          delete headers["content-length"];
          delete headers["transfer-encoding"];
          headers["content-length"] = Buffer.byteLength(rewritten);
          res.writeHead(upRes.statusCode || 502, headers);
          res.end(rewritten);
        });
      });

      upReq.on("error", (err) => {
        sendJson(res, 502, { ok: false, error: "Sandbox browser unavailable: " + err.message });
      });
      req.pipe(upReq);
    });

    server.on("upgrade", (req, socket, head) => {
      if (!isAllowedIp(req)) {
        socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        return;
      }
      if (!checkToken(req)) {
        socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        return;
      }
      const u = new URL(req.url, "http://localhost");
      if (!isAllowedCdpWsPath(u.pathname)) {
        socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
        return;
      }

      const upstream = net.createConnection(CDP_SOCK, () => {
        const lines = [req.method + " " + u.pathname + u.search + " HTTP/1.1"];
        for (let i = 0; i < req.rawHeaders.length; i += 2) {
          const k = req.rawHeaders[i];
          const v = req.rawHeaders[i + 1];
          const lk = k.toLowerCase();
          if (lk === "host") {
            lines.push("Host: 127.0.0.1:" + CDP_PORT);
          } else if (lk === "authorization" || lk === "origin") {
            continue;
          } else {
            lines.push(k + ": " + v);
          }
        }
        lines.push("", "");
        upstream.write(lines.join("\r\n"));
        if (head && head.length) upstream.write(head);
        socket.pipe(upstream);
        upstream.pipe(socket);
      });

      const onErr = () => {
        socket.destroy();
        upstream.destroy();
      };
      socket.on("error", onErr);
      upstream.on("error", onErr);
    });

    server.listen(PORT, "0.0.0.0", () => {
      console.log("muse-browser-gateway listening on 0.0.0.0:" + PORT);
    });
  '';

  startSandboxBrowser = pkgs.writeShellScript "start-muse-browser-sandbox" ''
    set -euo pipefail
    umask 077
    mkdir -p "${homeDir}/.config/muse-browser"
    if [ ! -s "${tokenFileHost}" ]; then
      ${pkgs.nodejs}/bin/node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("base64url"))' > "${tokenFileHost}"
      chmod 600 "${tokenFileHost}"
    fi

    mkdir -p \
      "${stateRoot}" \
      "${stateRoot}/cache" \
      "${stateRoot}/config" \
      "${stateRoot}/local/share/muse-browser" \
      "${stateRoot}/downloads" \
      "${ipcDirHost}" \
      "${waylandDirHost}"
    chmod 700 "${homeDir}/.config/muse-browser" "${stateRoot}" "${ipcDirHost}" "${waylandDirHost}"
    rm -f "${ipcDirHost}/cdp.sock" "${ipcDirHost}/ctl.sock" "${waylandDirHost}/wayland-0"

    ${pkgs.util-linux}/bin/unshare --user --map-root-user --net /bin/sh -c '
      ${museWaylandSecCtx}/bin/muse-wayland-secctx "${waylandDirHost}/wayland-0" &
      SECCTX_PID=$!
      trap "kill -TERM $SECCTX_PID 2>/dev/null || true" TERM INT EXIT
      for _ in $(seq 1 25); do
        [ -S "${waylandDirHost}/wayland-0" ] && break
        sleep 0.05
      done
      while ! ${pkgs.iproute2}/bin/ip route show default >/dev/null 2>&1; do
        sleep 0.05
      done
      for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.169.254/32; do
        ${pkgs.iproute2}/bin/ip route replace blackhole "$net"
      done
      ${pkgs.bubblewrap}/bin/bwrap \
        --ro-bind /nix /nix \
        --ro-bind /lib64 /lib64 \
        --ro-bind /run/current-system /run/current-system \
        --ro-bind /dev/null "${dbusBrokerBin}" \
        --ro-bind /etc /etc \
        --ro-bind "${resolvConfSandbox}" /etc/resolv.conf \
        --ro-bind /bin /bin \
        --ro-bind /usr /usr \
        --dev /dev \
        --dev-bind-try /dev/dri /dev/dri \
        --proc /proc \
        --tmpfs /tmp \
        --tmpfs /mnt \
        --tmpfs /run/user/${uidStr} \
        --bind "${ipcDirHost}" /run/user/${uidStr}/ipc \
        --bind "${waylandDirHost}" /run/user/${uidStr}/muse-wayland \
        --tmpfs "${homeDir}" \
        --bind "${stateRoot}/cache" "${homeDir}/.cache" \
        --bind "${stateRoot}/config" "${homeDir}/.config" \
        --bind "${stateRoot}/local" "${homeDir}/.local" \
        --bind "${stateRoot}/downloads" "${homeDir}/Downloads" \
        --clearenv \
        --setenv HOME "${homeDir}" \
        --setenv USER "${userName}" \
        --setenv __ETC_PROFILE_SOURCED "1" \
        --setenv LANG "en_US.UTF-8" \
        --setenv PATH "/run/current-system/sw/bin" \
        --setenv XDG_RUNTIME_DIR "/run/user/${uidStr}" \
        --setenv XDG_DATA_DIRS "/run/current-system/sw/share" \
        --setenv WAYLAND_DISPLAY "muse-wayland/wayland-0" \
        --setenv XDG_SESSION_TYPE "wayland" \
        --setenv NIXOS_OZONE_WL "1" \
        --setenv NIX_LD "/run/current-system/sw/share/nix-ld/lib/ld.so" \
        --setenv NIX_LD_LIBRARY_PATH "/run/current-system/sw/share/nix-ld/lib" \
        --chdir "${homeDir}" \
        --unshare-ipc \
        --unshare-uts \
        --unshare-user \
        --uid ${uidStr} \
        --gid ${uidStr} \
        --unshare-pid \
        --die-with-parent \
        -- ${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.nodejs}/bin/node "${sandboxCdpProxyJs}"
    ' &
    UNSHARE_PID=$!
    trap 'kill -TERM "$UNSHARE_PID" 2>/dev/null || true' TERM INT EXIT
    sleep 0.1
    ${pkgs.passt}/bin/pasta -q -4 -I tap0 -a 169.254.2.2 -n 24 -g 169.254.2.1 --config-net --no-map-gw -T none -U none -t none -u none --dns-forward 169.254.1.1 --dns-host 223.5.5.5 "$UNSHARE_PID"
    wait "$UNSHARE_PID"
  '';

  hostMuseBrowserOpen = ''
    #!/bin/sh
    set -eu
    SOCK="${ipcDirHost}/ctl.sock"
    URL="''${1:-}"
    ENC=$(${pkgs.nodejs}/bin/node -e 'process.stdout.write(encodeURIComponent(process.argv[1] || ""))' "$URL")
    exec /run/current-system/sw/bin/curl -sf --max-time 20 \
      --unix-socket "$SOCK" -X POST "http://localhost/open?url=$ENC" >/dev/null
  '';

  hostMuseBrowserCtl = ''
    #!/bin/sh
    set -eu
    CMD="''${1:-status}"
    case "$CMD" in
      status)
        systemctl --user --no-pager status muse-browser-gateway.service muse-browser.service || true
        echo "---"
        /run/current-system/sw/bin/curl -sf --unix-socket "${ipcDirHost}/ctl.sock" http://localhost/status || true
        echo ""
        ;;
      off|stop)
        systemctl --user stop muse-browser-gateway.service
        echo "muse-browser-gateway stopped (Tailscale 18790 disabled)"
        ;;
      on|start)
        systemctl --user start muse-browser.service muse-browser-gateway.service
        echo "muse-browser-gateway started (Tailscale 18790 enabled)"
        ;;
      toggle)
        if systemctl --user is-active --quiet muse-browser-gateway.service; then
          exec "$0" off
        else
          exec "$0" on
        fi
        ;;
      *)
        echo "Usage: muse-browserctl {status|on|off|toggle}" >&2
        exit 1
        ;;
    esac
  '';
in
{
  home.file.".local/bin/muse-browser" = {
    executable = true;
    text = hostMuseBrowserOpen;
  };

  home.file.".local/bin/muse-browserctl" = {
    executable = true;
    text = hostMuseBrowserCtl;
  };

  xdg.desktopEntries.muse-browser = {
    name = "Muse 沙盒浏览器";
    genericName = "Muse Isolated Sandbox Browser";
    exec = "${homeDir}/.local/bin/muse-browser %U";
    icon = "google-chrome";
    terminal = false;
    categories = [ "Network" "WebBrowser" ];
  };

  systemd.user.services.muse-browser = {
    Unit = {
      Description = "Muse Isolated Sandbox Browser (bwrap + pasta + Wayland secctx, CDP 9333)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      Wants = [ "muse-browser-gateway.service" ];
    };
    Service = {
      ExecStart = "${startSandboxBrowser}";
      Restart = "on-failure";
      RestartSec = 2;
      MemoryMax = "4G";
      CPUQuota = "400%";
      TasksMax = 2048;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.muse-browser-gateway = {
    Unit = {
      Description = "Muse Sandbox Browser CDP Gateway (port 18790 -> sandbox CDP 9333)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "muse-browser.service" ];
      Requires = [ "muse-browser.service" ];
    };
    Service = {
      ExecStart = "${pkgs.nodejs}/bin/node ${museGatewayJs}";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
