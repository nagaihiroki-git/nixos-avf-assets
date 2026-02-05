{
  description = "Pawn-VM: Pure SSH NixOS on Apple Virtualization Framework";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      configuration = { config, lib, modulesPath, pkgs, ... }: {
        imports = [ "${modulesPath}/profiles/minimal.nix" ];

        # Boot & Console
        boot.kernelParams = [ "console=hvc0" "elevator=none" ];
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "btrfs" ];
        boot.growPartition = true;
        boot.loader.grub.enable = false;

        # Storage (Btrfs with CoW + checksums)
        fileSystems."/" = {
          device = "/dev/vda1";
          fsType = "btrfs";
          options = [ "compress=zstd:1" "noatime" "space_cache=v2" ];
        };

        # Build acceleration (tmpfs for /tmp)
        boot.tmp.useTmpfs = true;
        boot.tmp.tmpfsSize = "50%";

        # Auto-resize Btrfs on boot
        systemd.services.btrfs-resize = {
          description = "Resize Btrfs to fill partition";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" "systemd-journald.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.btrfs-progs}/bin/btrfs filesystem resize max /";
          };
        };

        # Network & SSH
        networking.hostName = "pawn-vm";
        networking.firewall.allowedTCPPorts = [ 22 ];

        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "prohibit-password";
            PasswordAuthentication = false;
          };
        };

        # mDNS (pawn-vm.local)
        services.avahi = {
          enable = true;
          nssmdns4 = true;
          publish = {
            enable = true;
            addresses = true;
          };
        };

        # Root user with insecure key
        users.users.root = {
          openssh.authorizedKeys.keys = [
            # INSECURE KEY - Public, provides NO security. Replace for non-local use.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBYmCMI27aEewlbDkLqFDuc2VXrz3aK8cwy7G5xZAJTR pawn-vm-insecure-key"
          ];
        };

        # Minimal packages
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        environment.systemPackages = with pkgs; [ nix git btrfs-progs rsync ];

        system.stateVersion = "24.11";
      };

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ configuration ];
      };

      closureInfo = pkgs.closureInfo { rootPaths = [ nixos.config.system.build.toplevel ]; };
    in
    {
      # NixOS configuration for remote rebuild
      nixosConfigurations.pawn-vm = nixos;

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
