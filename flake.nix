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
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_gpu" "virtio_net" "virtiofs" ];
        boot.growPartition = true;

        fileSystems."/" = {
          device = "/dev/vda1";
          fsType = "ext4";
          autoResize = true;
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

      rootfsPartition = pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs.nix" {
        storePaths = [ nixos.config.system.build.toplevel ];
        volumeLabel = "nixos";
        populateImageCommands = ''
          mkdir -p ./files/etc
          echo "nixos-avf" > ./files/etc/hostname
          ln -s ${nixos.config.system.build.toplevel}/init ./files/init
        '';
      };
    in
    {
      packages.${system} = {
        kernel = nixos.config.system.build.kernel;
        initrd = nixos.config.system.build.initialRamdisk;

        rootfs = pkgs.runCommand "nixos-avf-gpt-image" {
          nativeBuildInputs = [ pkgs.gptfdisk pkgs.e2fsprogs pkgs.util-linux ];
        } ''
          PART_SIZE=$(stat -c%s "${rootfsPartition}")

          DISK_IMAGE=main.raw
          truncate -s $((PART_SIZE + 8 * 1024 * 1024)) $DISK_IMAGE

          sgdisk -n 1:2048:0 -t 1:8300 $DISK_IMAGE

          PART_END=$(sgdisk -p $DISK_IMAGE | awk '/^ *1 / {print $3}')
          PART_SECTORS=$((PART_END - 2048 + 1))
          PART_BYTES=$((PART_SECTORS * 512))
          PART_BLOCKS=$((PART_BYTES / 4096))

          echo "Partition: $PART_SECTORS sectors = $PART_BYTES bytes = $PART_BLOCKS blocks"

          cp ${rootfsPartition} part.img
          chmod +w part.img
          e2fsck -fy part.img || true
          resize2fs part.img ''${PART_BLOCKS}

          dd if=part.img of="$DISK_IMAGE" bs=512 seek=2048 conv=notrunc

          mkdir -p $out
          cp $DISK_IMAGE $out/main.raw
        '';

        default = pkgs.runCommand "avf-assets" { nativeBuildInputs = [ pkgs.zstd ]; } ''
          mkdir -p $out
          cp ${nixos.config.system.build.kernel}/${nixos.config.system.boot.loader.kernelFile} $out/vmlinuz
          cp ${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile} $out/initrd.img
          zstd -19 -T0 ${self.packages.${system}.rootfs}/main.raw -o $out/seed.raw.zst
        '';
      };
    };
}
