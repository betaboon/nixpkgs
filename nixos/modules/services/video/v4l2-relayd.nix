{ config, lib, pkgs, ... }:
with lib;
let

  cfg = config.services.v4l2-relayd;

  ipu6Platform = config.hardware.ipu6.platform;

  gst = (with pkgs.gst_all_1; [
    gst-plugins-bad
    gst-plugins-base
    gst-plugins-good
    gstreamer.out
  ]) ++ optional (ipu6Platform == "ipu6") pkgs.gst_all_1.icamerasrc-ipu6
  ++ optional (ipu6Platform == "ipu6ep") pkgs.gst_all_1.icamerasrc-ipu6ep;

in
{

  options.services.v4l2-relayd = {

    enable = mkEnableOption (lib.mdDoc "v4l2-relayd");

    cameraName = mkOption {
      type = types.str;
      default = "Intel MIPI Camera";
      description = "The name the camera will show up as.";
    };

    input = {
      format = mkOption {
        type = types.str;
        default = "YUY2";
        description = "The video-format to read from input-stream.";
      };

      width = mkOption {
        type = types.int;
        default = 1280;
        description = "The width to read from input-stream.";
      };

      height = mkOption {
        type = types.int;
        default = 720;
        description = "The height to read from input-stream.";
      };

      framerate = mkOption {
        type = types.int;
        default = 30;
        description = "The framerate to read from input-stream.";
      };
    };

    output = {
      format = mkOption {
        type = types.str;
        default = "YUY2";
        description = "The video-format to provide to output-stream.";
      };
    };

  };

  config = mkIf cfg.enable {

    boot = {
      extraModulePackages = with config.boot.kernelPackages; [
        v4l2loopback
      ];
      kernelModules = [
        "v4l2loopback"
      ];
      extraModprobeConfig = ''
        options v4l2loopback exclusive_caps=1 card_label="${cfg.cameraName}"
      '';
    };

    systemd.services.v4l2-relayd = {
      description = "Streaming relay for v4l2loopback using GStreamer";

      after = [ "modprobe@v4l2loopback.service" "systemd-logind.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        PrivateNetwork = true;
        PrivateTmp = true;
        LimitNPROC = 1;
      };

      environment.GST_PLUGIN_PATH = makeSearchPathOutput "lib" "lib/gstreamer-1.0" gst;

      script =
        let
          inputPipeline = "icamerasrc";

          outputPipeline = [
            "appsrc name=appsrc ${appsrcOptions}"
            "videoconvert"
          ] ++ optionals (cfg.input.format != cfg.output.format) [
            "video/x-raw,format=${cfg.output.format}"
            "queue"
          ] ++ [ "v4l2sink name=v4l2sink device=/dev/$DEVICE" ];

          appsrcOptions = concatStringsSep "," [
            "caps=video/x-raw"
            "format=${cfg.input.format}"
            "width=${toString cfg.input.width}"
            "height=${toString cfg.input.height}"
            "framerate=${toString cfg.input.framerate}/1"
          ];
        in
        ''
          DEVICE=$(grep -l -m1 -E "^${cfg.cameraName}$" /sys/devices/virtual/video4linux/*/name | cut -d / -f6)
          exec ${pkgs.v4l2-relayd}/bin/v4l2-relayd -i "${inputPipeline}" -o "${concatStringsSep " ! " outputPipeline}"
        '';
    };

  };

  meta.maintainers = with lib.maintainers; [ betaboon ];
}
