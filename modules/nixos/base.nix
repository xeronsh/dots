# Base system configuration: bootloader, primary user, sudo, kernel hardening, Nix, and CLI tools.
{ pkgs, lib, privateCfg, ... }:

{
  warnings = lib.optional (privateCfg.isExample or false)
    "Using public private-example stub; pass --override-input private path:/etc/nixos-private for real host deployment.";

  # ---------- 引导 ----------
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.editor = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10; # 保留 10 个 generation 可回滚
  boot.loader.timeout = 3;

  # ---------- 用户 ----------
  programs.fish.enable = true;
  users.users.${privateCfg.user.name} = {
    uid = privateCfg.user.uid;
    shell = pkgs.fish;
    isNormalUser = true;
    # Keep "input": DMS evdev manager (/proc/*/fd -> /dev/input/event*) reads 0660 root:input directly (no uaccess ACL).
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "ydotool" ];
    openssh.authorizedKeys.keys = privateCfg.user.authorizedKeys;
  };

  # Passwordless sudo for the single local user (agent automation needs it).
  security.sudo.execWheelOnly = true;
  security.sudo.extraRules = [{
    users = [ privateCfg.user.name ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];

  # ---------- 时区 / 语言 ----------
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = { LC_TIME = "zh_CN.UTF-8"; };
  console.keyMap = "us";

  # ---------- 内存：zram 交换，不启用休眠 ----------
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
  swapDevices = lib.mkForce [ ]; # 无磁盘 swap，故不提供 hibernate

  # ---------- 电源 / 硬件 ----------
  services.power-profiles-daemon.enable = true; # 与 TLP/auto-cpufreq 互斥，不要同时开
  services.fwupd.enable = true;
  services.libinput.enable = true;             # 触摸板
  hardware.bluetooth.enable = true;
  hardware.graphics.enable = true;
  services.fstrim.enable = true;

  # ---------- 内核深度加固 ----------
  security.protectKernelImage = true;
  boot.kernel.sysctl."net.core.bpf_jit_harden" = 2;

  # ---------- Nix：国内镜像 + flake + 自动维护 ----------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    allowed-users = [ "@wheel" ];
    trusted-users = lib.mkForce [ "root" ];
    substituters = [
      "https://mirrors.ustc.edu.cn/nix-channels/store"
      "https://cache.nixos.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    connect-timeout = 5;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
  nixpkgs.config.allowUnfree = true;

  # ---------- nix-ld：直接运行通用 Linux 预编译二进制（agy / pnpm / bun 等） ----------
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    openssl
  ];

  # ---------- 基础工具 ----------
  environment.systemPackages = with pkgs; [
    git vim tmux wget curl rsync btop pciutils usbutils ntfs3g fastfetch
    e2fsprogs # mkfs.ext4 / fsck / tune2fs（备份盘维护用）
  ];
}
