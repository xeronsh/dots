# Network, SSH, firewall, and Tailscale peer isolation.
{ config, lib, privateCfg, ... }:
let
  cdpAllowedIps = privateCfg.hosts.thinkpad.tailscale.cdpAllowedIps;
in
{
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ ];

  # Tailscale-only incoming SSH (port 22 stays closed on LAN/WAN; allowed on tailscale0 except isolated CDP peers).
  services.openssh = {
    enable = true;
    openFirewall = false;
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ privateCfg.user.name ];
      MaxAuthTries = 3;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      AllowTcpForwarding = "no";
    };
  };

  # ---------- Tailscale（tailnet 内 SSH 访问；仅允许 cdpAllowedIps 访问沙盒浏览器网关 18790） ----------
  services.tailscale = {
    enable = true;
    extraSetFlags = [ "--netfilter-mode=off" ];
  };
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  systemd.services.tailscaled = {
    after = [ "mihomo.service" ];
    wants = [ "mihomo.service" ];
    environment = {
      HTTP_PROXY = "http://127.0.0.1:7897";
      HTTPS_PROXY = "http://127.0.0.1:7897";
      NO_PROXY = "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10";
    };
  };
  networking.firewall.extraCommands = ''
    # Preserve CGNAT anti-spoofing (placed at #2, after #1 `-i lo -j nixos-fw-accept`).
    iptables -I nixos-fw 2 -s 100.64.0.0/10 ! -i tailscale0 -j DROP
  '' + lib.concatStrings (lib.imap0 (i: ip: ''
    # Clean legacy INPUT rules if upgrading via firewall-reload from an earlier generation.
    iptables -D INPUT -i tailscale0 -s ${ip} ! -p tcp -j DROP 2>/dev/null || true
    iptables -D INPUT -i tailscale0 -s ${ip} -p tcp ! --dport 18790 -j DROP 2>/dev/null || true
    # Isolate configured peer (${ip}) to TCP 18790 only before tailscale0/ping accepts (after lo, CGNAT & conntrack).
    iptables -I nixos-fw ${toString (4 + i * 3)} -i tailscale0 -s ${ip} -p tcp --dport 18790 -j nixos-fw-accept
    iptables -I nixos-fw ${toString (5 + i * 3)} -i tailscale0 -s ${ip} ! -p tcp -j DROP
    iptables -I nixos-fw ${toString (6 + i * 3)} -i tailscale0 -s ${ip} -p tcp ! --dport 18790 -j DROP
  '') cdpAllowedIps);
}
