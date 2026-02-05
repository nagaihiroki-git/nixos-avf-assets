{
  description = "Minimal NixOS for AVF with GPT Support";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      configuration = { config, lib, modulesPath, pkgs, ... }: {
        imports = [
          "${modulesPath}/profiles/minimal.nix"
        ];

        boot.kernelParams = [ "console=hvc0" ];
        boot.initrd.availableKernelModules = [
          "virtio_pci" "virtio_blk" "virtio_gpu" "virtio_net" "virtiofs"
          "nvme" "btrfs"
        ];
        boot.growPartition = true;

        fileSystems."/" = {
          device = "/dev/nvme0n1p1";
          fsType = "btrfs";
          options = [ "compress=zstd" "noatime" ];
        };

        fileSystems."/etc/nixos" = {
          device = "dotfiles";
          fsType = "virtiofs";
          options = [ "nofail" ];
        };

        users.users.root.initialPassword = "";
        services.getty.autologinUser = "root";
        networking.hostName = "nixos-avf";
        boot.loader.grub.enable = false;
        nix.settings.experimental-features = [ "nix-command" "flakes" ];

        environment.systemPackages = with pkgs; [
          git curl wget
        ];

        systemd.services.nixos-avf-rebuild = {
          description = "Auto rebuild NixOS from VirtioFS flake (First Boot Only)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          unitConfig.ConditionPathExists = "!/var/lib/nixos-avf-setup-done";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          path = with pkgs; [ nix git coreutils gnugrep inetutils iputils systemd ];
          script = ''
            set -euo pipefail

            GREEN='\033[0;32m'
            YELLOW='\033[1;33m'
            RED='\033[0;31m'
            NC='\033[0m'

            log() { echo -e "''${YELLOW}[nixos-avf] $1''${NC}" > /dev/console; }
            success() { echo -e "''${GREEN}[nixos-avf] $1''${NC}" > /dev/console; }
            error() { echo -e "''${RED}[nixos-avf] ERROR: $1''${NC}" > /dev/console; }

            FLAKE_PATH="/etc/nixos"
            HOSTNAME=$(hostname)

            log "Waiting for network..."
            for i in $(seq 1 60); do
              if ping -c 1 github.com > /dev/null 2>&1; then
                success "Network is up!"
                break
              fi
              sleep 1
            done

            [ ! -f "$FLAKE_PATH/flake.nix" ] && { log "No flake.nix, skipping"; exit 0; }

            log "Building system..."
            SYSTEM=$(nix build "$FLAKE_PATH#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
              --no-link --print-out-paths \
              --max-jobs 1 --option max-substitution-jobs 1 \
              2>&1 | tee /dev/console | tail -1)

            [ -z "$SYSTEM" ] || [ ! -d "$SYSTEM" ] && { error "Build failed!"; exit 1; }

            success "Build done: $SYSTEM"

            "$SYSTEM/bin/switch-to-configuration" boot

            touch /var/lib/nixos-avf-setup-done
            success "Rebooting..."
            sync && reboot
          '';
        };

        system.stateVersion = "24.11";
      };

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ configuration ];
      };

      closureInfo = pkgs.closureInfo { rootPaths = [ nixos.config.system.build.toplevel ]; };
    in
    {
      packages.${system} = {
        kernel = nixos.config.system.build.kernel;
        initrd = nixos.config.system.build.initialRamdisk;
        toplevel = nixos.config.system.build.toplevel;

        default = pkgs.runCommand "avf-assets" {} ''
          mkdir -p $out
          cp ${nixos.config.system.build.kernel}/${nixos.config.system.boot.loader.kernelFile} $out/vmlinuz
          cp ${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile} $out/initrd.img
          cp ${closureInfo}/store-paths $out/store-paths
          echo "${nixos.config.system.build.toplevel}" > $out/toplevel-path
        '';
      };
    };
}
