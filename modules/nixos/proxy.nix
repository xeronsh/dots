# 节点凭据仅保存在用户私有配置中，不进入 Nix store。
{ pkgs, privateCfg, ... }:
{
  environment.systemPackages = [ pkgs.mihomo ];

  networking.enableIPv6 = false;
  # 不要用 ipv6.disable=1 关内核 IPv6 栈：Waydroid 里 Android 13 的 IpClient 会反复
  # 写 /proc/sys/net/ipv6/conf/eth0/* 失败（EREMOTEIO），DHCP 永远拿不到 IP。
  # 主机层面靠上面的 enableIPv6 = false 关掉 IPv6 即可。
  # Use routable IPv4 resolvers so TUN captures DNS instead of bypassing via LAN.
  networking.networkmanager.dns = "none";
  networking.nameservers = [ "223.5.5.5" "119.29.29.29" ];

  # Dynamic user, runtime-only credentials and CAP_NET_ADMIN for transparent TUN.
  services.mihomo = {
    enable = true;
    configFile = "/home/${privateCfg.user.name}/.config/mihomo/config.yaml";
    webui = pkgs.zashboard;
    tunMode = true;
  };
  systemd.services.mihomo.serviceConfig = {
    Restart = "on-failure";
    RestartSec = 3;
  };
  environment.interactiveShellInit = ''
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  '';
}
