{
  description = "Minimal NixOS for AVF with Disko (GPT Support)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      configuration = { config, lib, modulesPath, pkgs, ... }: {
        imports = [
          "${modulesPath}/profiles/minimal.nix"
          disko.nixosModules.disko
        ];

        disko.devices = {
          disk = {
            main = {
              device = "/dev/vda";
              type = "disk";
              content = {
                type = "gpt";
                partitions = {
                  boot = {
                    size = "1M";
                    type = "EF02";
                  };
                  root = {
                    size = "100%";
                    content = {
                      type = "ext4";
                      mountpoint = "/";
                    };
                  };
                };
              };
            };
          };
        };

        boot.kernelParams = [ "console=hvc0" ];
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_gpu" "virtio_net" "virtiofs" ];
        boot.growPartition = true;

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
          git curl wget e2fsprogs
        ];

        systemd.services.nixos-avf-rebuild = {
          description = "Auto rebuild NixOS from VirtioFS flake";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "local-fs.target" "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ pkgs.nix pkgs.nixos-rebuild pkgs.git pkgs.coreutils pkgs.gnugrep pkgs.inetutils pkgs.iputils pkgs.e2fsprogs ];
          script = ''
            set -euo pipefail

            FLAKE_PATH="/etc/nixos"
            HOSTNAME=$(hostname)

            echo "Checking filesystem integrity..."
            if ! e2fsck -n /dev/vda2 > /dev/null 2>&1; then
              echo "!!! Filesystem error detected on /dev/vda2 !!!"
              echo "Run 'e2fsck -y /dev/vda2' manually to repair."
              exit 1
            fi

            for i in $(seq 1 60); do
              if ping -c 1 github.com > /dev/null 2>&1; then
                echo "Network is up"
                break
              fi
              echo "Waiting for network... ($i/60)"
              sleep 2
            done

            for i in $(seq 1 30); do
              [ -f "$FLAKE_PATH/flake.nix" ] && break
              sleep 1
            done

            if [ ! -f "$FLAKE_PATH/flake.nix" ]; then
              echo "No flake.nix found at $FLAKE_PATH, skipping"
              exit 0
            fi

            echo "Checking configuration..."
            if ! nix eval "$FLAKE_PATH#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" 2>&1; then
              echo "nix eval failed (error above), skipping"
              exit 0
            fi

            echo "Rebuilding..."
            nixos-rebuild switch --flake "$FLAKE_PATH#$HOSTNAME"
            echo "Done!"
          '';
        };

        system.stateVersion = "24.11";
      };

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ configuration ];
      };
    in
    {
      packages.${system} = {
        kernel = nixos.config.system.build.kernel;
        initrd = nixos.config.system.build.initialRamdisk;
        rootfs = nixos.config.system.build.diskoImages;

        default = pkgs.runCommand "avf-assets" { nativeBuildInputs = [ pkgs.zstd ]; } ''
          mkdir -p $out
          cp ${nixos.config.system.build.kernel}/${nixos.config.system.boot.loader.kernelFile} $out/vmlinuz
          cp ${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile} $out/initrd.img
          zstd -19 -T0 ${nixos.config.system.build.diskoImages}/main.raw -o $out/seed.raw.zst
        '';
      };
    };
}
