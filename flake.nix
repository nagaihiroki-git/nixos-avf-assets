{
  description = "Minimal NixOS kernel and initrd for Apple Virtualization Framework";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [{
        boot.kernelParams = [ "console=hvc0" ];
        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_gpu"
          "virtio_net"
          "virtiofs"
        ];
        boot.initrd.kernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_gpu"
          "virtio_net"
          "virtiofs"
        ];
        fileSystems."/" = {
          device = "/dev/vda";
          fsType = "ext4";
        };
        system.stateVersion = "24.11";
      }];
    };
  in {
    packages.${system} = {
      kernel = nixos.config.system.build.kernel;
      initrd = nixos.config.system.build.initialRamdisk;
      default = pkgs.linkFarm "avf-assets" [
        { name = "vmlinuz"; path = "${nixos.config.system.build.kernel}/${nixos.config.system.boot.loader.kernelFile}"; }
        { name = "initrd.img"; path = "${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile}"; }
      ];
    };
  };
}
