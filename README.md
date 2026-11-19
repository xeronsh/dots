# dots — ThinkPad T14s Gen3 NixOS Flake Configuration

KISS, local-first NixOS 26.05 workstation configuration (GPT + LUKS2 + Btrfs subvolumes, `niri` + `dms-shell`, Home Manager, and an isolated CDP sandbox browser).

精简、本地优先的 NixOS 26.05 工作站配置（全盘加密 + Btrfs 子卷、`niri` 合成器 + Home Manager 与隔离沙盒浏览器）。

## Repository Layout / 目录结构

```text
dots/
├── flake.nix                  # Flake inputs, devShells, NixOS + Home Manager wiring
├── flake.lock                 # Pinned dependency lockfile
├── private-example/flake.nix  # Public-safe stub input so `nix flake check` passes cleanly
├── hosts/thinkpad/            # Host profile & label-based hardware config (no UUIDs)
├── modules/
│   ├── nixos/                 # base, network (SSH/firewall/Tailscale), desktop, proxy
│   ├── home/                  # Home Manager, fish/starship, sandbox-browser
│   └── pkgs/                  # Out-of-tree packages (flclash, qqmusic, winc)
├── dotfiles/                  # Sanitized non-secret user dotfiles (reference / manual sync)
└── scripts/bootstrap.sh       # Disk partitioning & LUKS2 + Btrfs installer script
```

## Public vs Private Separation / 公私分离机制

- **Public stub (`./private-example/flake.nix`)**: Used by default for `inputs.private` so anyone cloning this repository can run `nix flake check` cleanly without private host data (`isExample = true`, emits a reminder warning during evaluation).
- **Local host data (`/etc/nixos-private/flake.nix`)**: Kept outside this Git repository (recommended `750 root:wheel` directory, `640 root:wheel` file) to hold non-secret host-specific values (`user.name`, `user.uid`, `user.authorizedKeys`, `user.gdriveAccounts`, `hosts.thinkpad.tailscale.cdpAllowedIps`).
- **Runtime secrets**: Never put tokens, API keys, or proxy node credentials into Nix flakes or `/nix/store`. Keep them in runtime user files with `0600` permissions (e.g., `~/.config/mihomo/config.yaml`, `~/.config/muse-browser/token`, `~/.config/rclone/rclone.conf`).

- **公开占位（`./private-example/flake.nix`）**：默认作为 `inputs.private`，保证公开仓库可直接通过纯 Flake 检查；构建时会给出启用 `private-example` 的提示警告。
- **本机私有输入（`/etc/nixos-private/flake.nix`）**：独立存放于本机 Git 仓库之外，保存用户名、UID、SSH 公钥、挂载账号名及允许访问沙盒 CDP 网关的 Tailscale Peer IP 等非密拓扑信息。
- **运行时凭据**：所有 Token、节点订阅、OAuth 凭据均保留在用户主目录运行时配置（`0600`），绝不进入 Nix Store。

## Usage / 常用命令

```bash
# Dry-check / evaluate with public stub
nix flake check

# Build & switch on the real host using local /etc/nixos-private
sudo nixos-rebuild switch --flake "$HOME/dots#thinkpad" --override-input private path:/etc/nixos-private

# Enter an opt-in toolchain devShell (node, python, go, rust, c)
nix develop "$HOME/dots#python"
```

## USTC Mirror Note / 国内镜像说明

`flake.nix` (`inputs.nixpkgs.url`) and `modules/nixos/base.nix` (`nix.settings.substituters`) default to USTC mirrors (`mirrors.ustc.edu.cn`) for reliable downloads in mainland China. If you are outside mainland China, switch `inputs.nixpkgs.url` to `github:NixOS/nixpkgs/nixos-26.05` (or `nixos-unstable`) and remove the USTC substituter entry in `modules/nixos/base.nix`.

默认使用中科大镜像源加速 `nixpkgs` 与二进制缓存拉取；海外网络环境可切换回上游 `github:NixOS/nixpkgs` 与 `cache.nixos.org`。

## `dotfiles/` Reference Note / 用户配置说明

`dotfiles/` holds sanitized, non-secret desktop and CLI configs (`niri`, `kitty`, `tmux`, `fish`, etc.) for reference and portability. DMS-managed files under `~/.config/` remain writable on disk so desktop runtime changes are not overwritten by read-only Home Manager symlinks.

`dotfiles/` 收录了已脱敏的桌面与终端配置作备份参考；`~/.config/` 下由 DMS 运行时写入的配置文件保持可写，不由 Home Manager 只读接管。
