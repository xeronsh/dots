{
  description = "Example (public-safe) private data stub for NixOS flake evaluation";

  outputs = _: {
    data = {
      isExample = true;
      user = {
        name = "user";
        uid = 1000;
        authorizedKeys = [ ];
        gdriveAccounts = [ ];
      };
      hosts.thinkpad.tailscale.cdpAllowedIps = [ ];
    };
  };
}
