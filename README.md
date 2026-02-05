# Pawn-VM: Pure SSH NixOS on Apple Virtualization Framework

Minimal NixOS VM for Apple Silicon, managed entirely via SSH. No shared folders, no magic - just a clean remote builder.

## Quick Start

```bash
# Download and run
curl -LO https://github.com/YOUR_ORG/pawn-vm/releases/latest/download/{vmlinuz,initrd.img,seed.raw.zst,insecure_key}
zstd -d seed.raw.zst -o disk.raw
chmod 600 insecure_key

# Start VM (using your AVF launcher)
pawn-runner --kernel vmlinuz --initrd initrd.img --disk disk.raw

# Connect
ssh -i insecure_key root@pawn-vm.local
```

## SSH Setup

### Insecure Key Warning

This repo includes a **publicly known SSH key** for development convenience (Vagrant-style).

**⚠️ This key provides ZERO security.** Replace it for any non-local usage.

### ~/.ssh/config

```
Host pawn-vm
    HostName pawn-vm.local
    User root
    IdentityFile ~/path/to/insecure_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

## Remote Rebuild (Pure SSH Workflow)

Update the VM directly from your Mac:

```bash
# From your flake directory
nixos-rebuild switch \
  --flake .#pawn-vm \
  --target-host root@pawn-vm.local \
  --build-host root@pawn-vm.local
```

This:
1. Transfers your flake to the VM via SSH
2. Builds on VM's tmpfs (fast, uses RAM)
3. Activates the new configuration

## Use as Remote Builder

Add to `/etc/nix/machines`:

```
ssh://root@pawn-vm.local aarch64-linux ~/path/to/insecure_key 6 1 big-parallel,kvm
```

Or `~/.config/nix/nix.conf`:

```nix
builders = ssh://root@pawn-vm.local aarch64-linux
builders-use-substitutes = true
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Mac (Host)                                         │
│  ┌───────────────────────────────────────────────┐  │
│  │  nixos-rebuild --target-host pawn-vm.local    │  │
│  └───────────────────┬───────────────────────────┘  │
│                      │ SSH                          │
│  ┌───────────────────▼───────────────────────────┐  │
│  │  Pawn-VM (AVF Guest)                          │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  /tmp (tmpfs 50% RAM) ← Build here      │  │  │
│  │  │  / (Btrfs, zstd:1, CoW)                 │  │  │
│  │  │  SSH + Avahi (pawn-vm.local)            │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Specs

| Component | Value |
|-----------|-------|
| Filesystem | Btrfs (`compress=zstd:1,noatime,discard=async,commit=60`) |
| /tmp | tmpfs (50% RAM) |
| Initial Disk | 4GB (auto-expands on boot) |
| SSH | Port 22, key-only |
| mDNS | `pawn-vm.local` |

## Why Pure SSH?

- **No VirtioFS overhead** - Eliminates slow small-file I/O
- **No host dependency** - VM doesn't need to know host's folder structure
- **Git-managed state** - All changes tracked in your flake
- **Reproducible** - Same seed image everywhere, SSH applies diffs

## License

MIT
