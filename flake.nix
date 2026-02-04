{
  description = "Minimal NixOS kernel, initrd and rootfs for Apple Virtualization Framework";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      configuration = { config, lib, modulesPath, pkgs, ... }: {
        imports = [ "${modulesPath}/profiles/minimal.nix" ];

        boot.kernelParams = [ "console=hvc0" ];
        boot.initrd.availableKernelModules = [
          "virtio_pci" "virtio_blk" "virtio_gpu" "virtio_net" "virtiofs"
        ];
        boot.initrd.kernelModules = [
          "virtio_pci" "virtio_blk" "virtio_gpu" "virtio_net" "virtiofs"
        ];

        fileSystems."/" = {
          device = "/dev/vda";
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
          coreutils
          gnused
          gnugrep
          gawk
          findutils
          diffutils
          bash
          gnutar
          gzip
          xz
          git
          curl
          wget
        ];

        systemd.services.resize-root = {
          description = "Resize root filesystem to fill disk";
          wantedBy = [ "multi-user.target" ];
          before = [ "nixos-avf-rebuild.service" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ pkgs.e2fsprogs ];
          script = ''
            resize2fs /dev/vda || true
          '';
        };

        systemd.services.nixos-avf-rebuild = {
          description = "Auto rebuild NixOS from VirtioFS flake";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ pkgs.nix pkgs.nixos-rebuild pkgs.git pkgs.coreutils pkgs.gnugrep pkgs.inetutils ];
          script = ''
            set -euo pipefail

            FLAKE_PATH="/etc/nixos"
            HOSTNAME=$(hostname)
            LOG_FILE="$FLAKE_PATH/.nixos-avf-rebuild.log"
            DEBUG_FLAG="$FLAKE_PATH/.nixos-avf-debug"

            log() {
              local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
              echo "$msg"
              echo "$msg" >> "$LOG_FILE"
            }

            debug() {
              if [ -f "$DEBUG_FLAG" ]; then
                log "[DEBUG] $1"
              fi
            }

            echo "=== nixos-avf-rebuild started at $(date) ===" > "$LOG_FILE"
            log "HOSTNAME: $HOSTNAME"
            [ -f "$DEBUG_FLAG" ] && log "Debug mode enabled"

            debug "Waiting for flake.nix..."
            for i in $(seq 1 30); do
              [ -f "$FLAKE_PATH/flake.nix" ] && break
              debug "Attempt $i: flake.nix not found, sleeping..."
              sleep 1
            done

            if [ ! -f "$FLAKE_PATH/flake.nix" ]; then
              log "No flake.nix found at $FLAKE_PATH, skipping auto-rebuild"
              exit 0
            fi
            debug "Found flake.nix"

            log "Checking nix configuration..."
            if ! nix eval "$FLAKE_PATH#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" >> "$LOG_FILE" 2>&1; then
              log "nix eval failed, see $LOG_FILE for details"
              echo "=== nix eval error ===" >> "$LOG_FILE"
              nix eval "$FLAKE_PATH#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" 2>&1 >> "$LOG_FILE" || true
              exit 0
            fi
            debug "nix eval succeeded"

            log "Rebuilding NixOS from $FLAKE_PATH#$HOSTNAME..."
            if nixos-rebuild switch --flake "$FLAKE_PATH#$HOSTNAME" >> "$LOG_FILE" 2>&1; then
              log "Rebuild complete!"
            else
              log "Rebuild failed, see $LOG_FILE for details"
              exit 1
            fi
          '';
        };

        system.stateVersion = "24.11";
      };

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ configuration ];
      };

      rootfsImage = pkgs.callPackage "${nixpkgs}/nixos/lib/make-ext4-fs.nix" {
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
        rootfs = rootfsImage;
        default = pkgs.runCommand "avf-assets" { nativeBuildInputs = [ pkgs.zstd ]; } ''
          mkdir -p $out
          cp ${nixos.config.system.build.kernel}/${nixos.config.system.boot.loader.kernelFile} $out/vmlinuz
          cp ${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile} $out/initrd.img
          zstd -19 -T0 ${rootfsImage} -o $out/seed.raw.zst
        '';
      };
    };
}
