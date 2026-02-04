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
        boot.initrd.checkJournalingFS = true;

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

            # Check filesystem integrity before any writes
            echo "Checking filesystem integrity..."
            if ! e2fsck -n /dev/vda > /dev/null 2>&1; then
              echo "!!! Filesystem error detected on /dev/vda !!!"
              echo "Run 'e2fsck -y /dev/vda' manually to repair."
              exit 1
            fi

            # Wait for network
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
