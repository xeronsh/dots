{
  description = "ThinkPad T14s Gen3 — NixOS 26.05 (KISS, 全盘加密笔记本)";

  # 用国内镜像拉 nixpkgs，避免 GitHub 依赖（实测 GitHub 直连超时）
  inputs.nixpkgs.url = "https://mirrors.ustc.edu.cn/nix-channels/nixos-26.05/nixexprs.tar.xz";

  # Only chat apps follow a newer pinned package set; the OS stays on its lock.
  inputs.nixpkgs-chat.url = "github:NixOS/nixpkgs/nixos-unstable";

  # DMS 2.0（AvengeMedia → duxlabs-dev，app id 改 dev.duxlabs.shell）。
  # 只借它的 mkDmsShell 包定义，不引入 programs.dank-material-shell 模块，
  # 因此 modules/home 里自定义的 systemd unit 与 niri 快捷键完全不变。
  inputs.dux-shell = {
    url = "github:duxlabs-dev/dux-shell/v2.1.2";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.home-manager = {
    url = "github:nix-community/home-manager/release-26.05";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Public-safe stub by default; override on real host with:
  #   --override-input private path:/etc/nixos-private
  inputs.private.url = "path:./private-example";

  outputs = { self, nixpkgs, nixpkgs-chat, dux-shell, home-manager, private }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    privateCfg = private.data;
  in {
    # Explicit opt-in toolchains; none are added to the global desktop PATH.
    devShells.${system} = {
      node = pkgs.mkShell { packages = with pkgs; [ nodejs pnpm ]; };
      python = pkgs.mkShell { packages = with pkgs; [ uv python3 ]; };
      go = pkgs.mkShell { packages = with pkgs; [ go ]; };
      rust = pkgs.mkShell {
        packages = with pkgs; [ rustc cargo rustfmt clippy gcc pkg-config ];
      };
      c = pkgs.mkShell { packages = with pkgs; [ gcc gnumake pkg-config ]; };
    };

    nixosConfigurations.thinkpad = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        chatPkgs = import nixpkgs-chat {
          inherit system;
          config.allowUnfree = true;
        };
        inherit privateCfg;
      };
      modules = [
        # 用 overlay 直接替换包，modules/nixos/desktop.nix 与 modules/home 里的 ${pkgs.dms-shell} 无需改动。
        {
          nixpkgs.overlays = [
            (final: prev: { dms-shell = dux-shell.lib.mkDmsShell prev; })
          ];
        }
        ./hosts/thinkpad
        home-manager.nixosModules.home-manager
        {
          environment.systemPackages = [ home-manager.packages.${system}.home-manager ];
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "before-home-manager";
          home-manager.extraSpecialArgs = { inherit privateCfg; };
          home-manager.users.${privateCfg.user.name} = import ./modules/home;
        }
      ];
    };
  };
}
