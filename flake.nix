{
  description = "Pawn-VM: Pure SSH NixOS on Apple Virtualization Framework (16KB + XFS)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-apple-silicon = {
      url = "github:tpwrules/nixos-apple-silicon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-apple-silicon }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      configuration = { config, lib, modulesPath, pkgs, ... }: {
        imports = [
          "${modulesPath}/profiles/minimal.nix"
          nixos-apple-silicon.nixosModules.apple-silicon-support
        ];

        # 16KB page size kernel (Asahi Linux)
        hardware.asahi.enable = true;
        boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage "${nixos-apple-silicon}/packages/linux-asahi" {});

        # Boot & Console (JIT enabled - safe with 16KB pages)
        boot.kernelParams = [ "console=hvc0" "elevator=none" ];
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "xfs" ];
        boot.growPartition = true;
        boot.loader.grub.enable = false;

        # Storage (XFS - rock solid, no alignment issues)
        fileSystems."/" = {
          device = "/dev/vda1";
          fsType = "xfs";
          options = [ "noatime" ];
        };

        # Build acceleration (tmpfs for /tmp)
        boot.tmp.useTmpfs = true;
        boot.tmp.tmpfsSize = "50%";

        # Auto-resize XFS on boot
        systemd.services.xfs-growfs = {
          description = "Grow XFS to fill partition";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.xfsprogs}/bin/xfs_growfs /";
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
        environment.systemPackages = with pkgs; [ nix git xfsprogs rsync ];

        system.stateVersion = "24.11";
      };

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ configuration ];
        specialArgs = { inherit nixos-apple-silicon; };
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
