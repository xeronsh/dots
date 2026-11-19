# Home Manager owns shell/session integration. DMS and desktop configs remain writable
# under ~/.config, as DMS updates its generated files at runtime.
{ config, pkgs, privateCfg, ... }:
let
  gdriveAccounts = privateCfg.user.gdriveAccounts;
  mkGdriveService = name: {
    name = "rclone-gdrive-${name}";
    value = {
      Unit = {
        Description = "Google Drive FUSE mount (${name})";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        # Only start when the remote is already authorized in rclone.conf
        ConditionPathExists = "%h/.config/rclone/rclone.conf";
      };
      Service = {
        Type = "notify";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/GoogleDrive/${name} %h/.cache/rclone";
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone mount ${name}: %h/GoogleDrive/${name} \
            --vfs-cache-mode full \
            --vfs-cache-max-size 10G \
            --vfs-cache-max-age 72h \
            --dir-cache-time 72h \
            --vfs-read-chunk-size 32M \
            --umask 022
        '';
        ExecStop = "/run/wrappers/bin/fusermount3 -uz %h/GoogleDrive/${name}";
        Restart = "on-failure";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
in
{
  imports = [ ./sandbox-browser.nix ];
  home.username = privateCfg.user.name;
  home.homeDirectory = "/home/${privateCfg.user.name}";
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  xdg.enable = true;
  # Keep Qt's Documents location consistent with the migrated WeChat data.
  xdg.configFile."user-dirs.dirs".text = ''
    XDG_DOCUMENTS_DIR="$HOME/Documents"
  '';

  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/.npm-global/bin"
  ];
  home.sessionVariables = {
    EDITOR = "vim";
    QT_IM_MODULE = "fcitx";
    XMODIFIERS = "@im=fcitx";
  };
  programs.fish = {
    enable = true;
    shellAliases = {
      ".." = "cd ..";
      "..." = "cd ../..";
      cat = "bat";
      ls = "eza --icons";
      ll = "eza -l --icons";
      la = "eza -la --icons";
      tree = "eza --tree --icons";
      g = "git";
      ga = "git add";
      gc = "git commit";
      gl = "git pull";
      gp = "git push";
      gs = "git status";
      p = "pi";
      hms = "sudo nixos-rebuild switch --flake $HOME/dots#thinkpad --override-input private path:/etc/nixos-private";
      find = "fd";
      grep = "rg";
      hm = "home-manager";
      hme = "$EDITOR $HOME/dots/modules/home/default.nix";
      colab-login = "gcloud auth application-default login --scopes=openid,https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/colaboratory";
    };
    interactiveShellInit = builtins.readFile ./fish-interactive.fish;
  };

  # nixpkgs 的 VS Code 包装脚本会给 `code` 追加 4 个 Electron/Chromium 参数，
  # VS Code 的 CLI 解析器不认识它们，每次都在 stderr 打 4 行 Warning。
  # 纯噪音（参数仍会照常传给 Electron），这里只过滤这几行，真正的报错不受影响。
  home.file.".local/bin/code" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      err=$(mktemp)
      /run/current-system/sw/bin/code --force-renderer-accessibility "$@" 2>"$err"
      status=$?
      grep -vE "(ozone-platform-hint|enable-features|enable-wayland-ime|wayland-text-input-version).*not in the list of known options" "$err" >&2
      rm -f "$err"
      exit $status
    '';
  };

  # Chrome uses basic store (autologin never unlocks keyring) + AT-SPI accessibility for agent-desktop.
  home.file.".local/bin/google-chrome" = {
    executable = true;
    text = ''
      #!/bin/sh
      exec /run/current-system/sw/bin/google-chrome \
        --password-store=basic \
        --force-renderer-accessibility "$@"
    '';
  };

  # WeChat's Qt/CEF chat input must use the Wayland text-input protocol;
  # the global QT_IM_MODULE=fcitx otherwise falls back to X11 and places the
  # fcitx5 candidate window far away from the caret.
  home.file.".local/bin/wechat" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_IM_MODULE=text-input-unstable-v3
      export QT_QPA_PLATFORM=wayland
      exec /run/current-system/sw/bin/wechat "$@"
    '';
  };

  # Reopen WeChat after it hides in the SNI tray, or raise an existing window.
  home.file.".local/bin/wechat-focus" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu
      pid=$(pgrep -x wechat | head -n1 || true)
      if [ -n "$pid" ]; then
        item=$(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
          org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null \
          | tr ' ' '\n' | grep "StatusNotifierItem-''${pid}-" | head -n1 | tr -d '"' || true)
        if [ -n "$item" ]; then
          service=''${item%%/*}
          path=/''${item#*/}
          busctl --user call "$service" "$path" org.kde.StatusNotifierItem Activate ii 0 0 >/dev/null 2>&1 && exit 0
        fi
      fi
      window_id=$(niri msg windows 2>/dev/null | awk '
        /Window ID/ { id = $3 }
        /App ID: "wechat"/ { gsub(":", "", id); print id; exit }
      ' || true)
      if [ -n "$window_id" ]; then
        niri msg action focus-window --id "$window_id" >/dev/null 2>&1 && exit 0
      fi
      exec ${config.home.homeDirectory}/.local/bin/wechat
    '';
  };

  xdg.desktopEntries.google-chrome = {
    name = "Google Chrome";
    genericName = "Web Browser";
    exec = "${config.home.homeDirectory}/.local/bin/google-chrome %U";
    icon = "google-chrome";
    terminal = false;
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
  };

  home.file.".local/share/applications/wechat.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=微信
    GenericName=WeChat
    Comment=WeChat desktop
    Exec=${config.home.homeDirectory}/.local/bin/wechat %U
    Icon=wechat
    Terminal=false
    Categories=Utility;
    StartupNotify=true
    StartupWMClass=wechat
  '';

  xdg.desktopEntries.mihomo-dashboard = {
    name = "代理管理 (Zashboard)";
    genericName = "Mihomo Dashboard";
    exec = "${config.home.homeDirectory}/.local/bin/google-chrome http://127.0.0.1:9090/ui/";
    icon = "network-vpn";
    terminal = false;
    categories = [ "Network" "Settings" ];
  };

  programs.starship = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ./starship.toml);
  };

  # Enable without starting a graphical session from SSH; niri-session starts it locally.
  systemd.user.services = (builtins.listToAttrs (map mkGdriveService gdriveAccounts)) // {
    dms = {
      Unit = {
        Description = "Dank Material Shell";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "org.freedesktop.Notifications";
        Environment = [
          "QT_QPA_PLATFORMTHEME=qt6ct"
          "LANG=zh_CN.UTF-8"
          "LC_ALL=zh_CN.UTF-8"
        ];
        ExecStart = "${pkgs.dms-shell}/bin/dms run --session";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Reminder only: no unattended source update, activation or reboot.
    nixos-update-reminder = {
      Unit.Description = "Weekly NixOS update reminder";
      Service = {
        Type = "oneshot";
        ExecStart = toString (pkgs.writeShellScript "nixos-update-reminder" ''
          if ${pkgs.systemd}/bin/systemctl --user --quiet is-active dms.service; then
            exec ${pkgs.dms-shell}/bin/dms notify "NixOS 更新提醒" "请检查 flake 更新，构建验证后手动应用；系统不会自动升级或重启。"
          fi
        '');
      };
    };
  };
  systemd.user.timers.nixos-update-reminder = {
    Unit = {
      Description = "Weekly NixOS update reminder";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      OnCalendar = "Mon *-*-* 10:00:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
