# Agent-first desktop: niri + DMS, browser, terminal, and essential CLI tools.
{ pkgs, chatPkgs, privateCfg, ... }:

{
  # ---------- 桌面会话 ----------
  programs.niri.enable = true; # 提供 niri / niri-session，并注册 Wayland 会话

  # Auto-login once at boot after LUKS unlock; logout still requires authentication.
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings = {
      initial_session = {
        user = privateCfg.user.name;
        command = "${pkgs.niri}/bin/niri-session";
      };
      default_session = {
        user = "greeter";
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd ${pkgs.niri}/bin/niri-session";
      };
    };
  };
  qt = {
    enable = true;
    platformTheme = "qt5ct"; # Installs Qt5/Qt6 platform plugins; DMS writes their icon settings.
  };

  services.gnome.gnome-keyring.enable = true;
  services.gnome.at-spi2-core.enable = true; # AT-SPI2 无障碍总线（agent-desktop 依赖）
  programs.ydotool.enable = true; # Wayland 通用键鼠输入后端（ydotoold + /run/ydotoold/socket）
  # niri 由 greetd 拉起：登录时同一密码自动解锁 login keyring，避免读写 secrets 弹解锁框
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.polkit.enable = true;
  services.upower.enable = true;
  services.udisks2.enable = true; # nautilus 挂载 U 盘/移动硬盘
  services.gvfs.enable = true; # 卷监视器：侧边栏显示磁盘卷、回收站、网络

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      xdg-desktop-portal-gnome
    ];
    config.common.default = [
      "gnome"
      "gtk"
    ];
  };

  # Winc 作为 md / json / 纯文本等文件的默认编辑器（文件管理器、xdg-open 打开方式）。
  xdg.mime.defaultApplications = {
    "text/markdown" = "winc.desktop";
    "text/plain" = "winc.desktop";
    "application/json" = "winc.desktop";
    "application/x-yaml" = "winc.desktop";
    "text/yaml" = "winc.desktop";
    "application/toml" = "winc.desktop";
    "application/xml" = "winc.desktop";
    "text/xml" = "winc.desktop";
    "text/csv" = "winc.desktop";
    "application/javascript" = "winc.desktop";
    "text/javascript" = "winc.desktop";
    "text/css" = "winc.desktop";
    "text/x-python" = "winc.desktop";
    "text/x-rust" = "winc.desktop";
    "text/x-go" = "winc.desktop";
    "text/x-csrc" = "winc.desktop";
    "text/x-c++src" = "winc.desktop";
    "text/x-java" = "winc.desktop";
    "text/x-shellscript" = "winc.desktop";
    "application/x-shellscript" = "winc.desktop";
  };

  # ---------- 音频 ----------
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = false;
    pulse.enable = true;
    jack.enable = false;
  };

  # ---------- 输入法：fcitx5 + rime ----------
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      fcitx5-rime
      qt6Packages.fcitx5-chinese-addons
      fcitx5-gtk
    ];
  };

  # ---------- 字体 ----------
  fonts = {
    enableDefaultPackages = false;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      source-han-sans
      maple-mono.NF-CN
    ];
    fontconfig.defaultFonts = {
      sansSerif = [
        "Source Han Sans SC"
        "Noto Sans CJK SC"
        "Noto Sans"
      ];
      serif = [ "Noto Serif CJK SC" ];
      monospace = [
        "Maple Mono NF CN"
        "Noto Sans Mono CJK SC"
      ];
      emoji = [ "Noto Color Emoji" ];
    };

    # AppImage/老版 Electron 自带的 HarfBuzz 无法枚举 Noto Sans CJK 2.004 的
    # 可变字体集合（NotoSansCJK-VF.otf.ttc），会退化成方框。这里把显式请求
    # "Noto Sans CJK SC" 的应用重定向到静态的思源黑体。
    fontconfig.localConf = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <match target="pattern">
          <test name="family" qual="any"><string>Noto Sans CJK SC</string></test>
          <edit name="family" mode="assign" binding="strong"><string>Source Han Sans SC</string></edit>
        </match>
      </fontconfig>
    '';
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1"; # Electron/Chromium 走 Wayland
    MOZ_ENABLE_WAYLAND = "1";
    ACCESSIBILITY_ENABLED = "1"; # Chromium/Electron 启用 AT-SPI 无障碍树
    QT_ACCESSIBILITY = "1"; # Qt 应用启用 AT-SPI 无障碍树
  };

  # ---------- 软件 ----------
  environment.systemPackages = with pkgs; [
    # 终端 / 桌面组件
    kitty
    quickshell
    dms-shell
    # Icon/cursor fallbacks are not pulled in by the minimal niri session.
    papirus-icon-theme
    adwaita-icon-theme
    bibata-cursors
    matugen
    dgop
    xwayland-satellite
    xdg-utils
    # Browser profile and credentials are migrated privately, never into Nix store.
    google-chrome
    chatPkgs.telegram-desktop
    chatPkgs.wechat
    libsecret
    (import ../pkgs/flclash.nix { inherit pkgs; })
    # DMS owns launchers, notifications, wallpaper, audio, network and Bluetooth UI.
    nautilus
    # 截图 / 剪贴板 / 输入模拟 / 通知 / 媒体键
    grim
    slurp
    satty
    xsel
    wl-clipboard
    wtype
    libnotify
    # 录屏（CLI 录屏 + OBS）
    wf-recorder
    wl-screenrec
    obs-studio
    mpv
    brightnessctl
    playerctl
    # 音乐（腾讯官方 Linux 客户端，登录即用会员）
    (import ../pkgs/qqmusic.nix { inherit pkgs; })
    # 编辑器
    vscode
    (import ../pkgs/winc.nix { inherit pkgs; })
    # CLI 常用
    bat
    eza
    fd
    ripgrep
    jq
    gh
    unzip
    file
    rclone
    google-cloud-sdk
    # Agent runtimes; project toolchains live in flake devShells.
    uv
    nodejs
  ];
}
