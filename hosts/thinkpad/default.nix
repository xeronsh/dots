# ThinkPad T14s Gen3 (Ryzen 7 PRO 6850U) — KISS 加密笔记本
# Local-first agent workstation: encrypted storage, minimal exposure, rollback.
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/network.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/proxy.nix
  ];

  networking.hostName = "thinkpad";

  # ---------- 外接备份盘 ----------
  # 按卷标挂载；nofail + automount 保证没插盘也能正常开机，插上后访问即挂载。
  fileSystems."/mnt/backup" = {
    device = "/dev/disk/by-label/backup";
    fsType = "ext4";
    options = [
      "nofail"
      "noatime"
      "x-gvfs-show"
      "x-gvfs-name=备份盘"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.device-timeout=10s"
    ];
  };

  system.stateVersion = "26.05";
}
