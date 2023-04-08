{ config, lib, pkgs, ... }:
with lib;
let

  cfg = config.hardware.ipu6;

  kernelPackages = config.boot.kernelPackages;

in
{

  options.hardware.ipu6 = {

    enable = mkEnableOption (lib.mdDoc "ipu6 kernel module");

    platform = mkOption {
      default = "ipu6";
      type = types.enum [ "ipu6" "ipu6ep" ];
      description = lib.mdDoc ''
        Set platform to enable kernel module for.
      '';
    };

  };

  config = mkIf cfg.enable {

    boot.extraModulePackages = [ kernelPackages.ipu6-drivers ];

    hardware.firmware = optional (cfg.platform == "ipu6") pkgs.ipu6-camera-bin
      ++ optional (cfg.platform == "ipu6ep") pkgs.ipu6ep-camera-bin;

    services.udev.extraRules = ''
      SUBSYSTEM=="intel-ipu6-psys", MODE="0660", GROUP="video"
    '';

    services.v4l2-relayd = {
      enable = mkDefault true;
      input.format = mkIf (cfg.platform == "ipu6ep") (mkDefault "NV12");
    };

  };

}
