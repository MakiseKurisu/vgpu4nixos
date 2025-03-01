{ pkgs, lib, config, inputs, ... }@args:

with lib;

let
  nvidiaCfg = config.hardware.nvidia;

  genXmlstarletCmd = overrides: lib.attrsets.foldlAttrs (s: n: v:
    s + (lib.attrsets.foldlAttrs (s': n': v': let
      vFlags = if builtins.isAttrs v' then
          # yes, three nested loops
          (lib.attrsets.foldlAttrs(ss: nn: vv: ss + " -u '/vgpuconfig/vgpuType[@id=\"${n}\"]/${n'}/@${nn}' -v ${vv}") "" v')
        else
          " -u '/vgpuconfig/vgpuType[@id=\"${n}\"]/${n'}/text()' -v ${builtins.toString v'}";
    in s' + vFlags) "" v)
    ) "xmlstarlet ed -P" overrides;

  xmlstarletCmd = genXmlstarletCmd (lib.mapAttrs (_: v:
    (optionalAttrs (v.vramAllocation != null) (let
      # a little bit modified version of
      # https://discord.com/channels/829786927829745685/1162008346551926824/1171897739576086650
      profSizeDec = 1048576 * v.vramAllocation;
      fbResDec = 134217728 + ((v.vramAllocation - 1024) * 65536);
    in {
      profileSize = "0x${lib.toHexString profSizeDec}";
      framebuffer = "0x${lib.toHexString (profSizeDec - fbResDec)}";
      fbReservation = "0x${lib.toHexString fbResDec}";
    }))
    // (optionalAttrs (v.heads != null) { numHeads = (builtins.toString v.heads); })
    // (optionalAttrs (v.display.width != null && v.display.height != null) {
      display = {
        width = (builtins.toString v.display.width);
        height = (builtins.toString v.display.height);
      };
      maxPixels = (builtins.toString (v.display.width * v.display.height));
    })
    // (optionalAttrs (v.framerateLimit != null) {
      frlConfig = "0x${lib.toHexString v.framerateLimit}";
      frame_rate_limiter = if v.framerateLimit > 0 then "1" else "0";
    })
    // v.xmlConfig
  ) nvidiaCfg.vgpu.patcher.profileOverrides);
in
{
  options = {
    hardware.nvidia.vgpu = {
      patcher = {
        options.remapP40ProfilesToV100D = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allows Pascal GPUs which use profiles from P40 to use latest guest drivers. Otherwise you're stuck with 16.x drivers. Not
            required for Maxwell GPUs. Only for 17.x releases.
          '';
        };
        runtimeOptions = {
          enable = lib.mkEnableOption "vGPU runtime options";
          vgpukvm = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              This option is provided by vgpu-kvm-optional-vgpu-v2.patch.

              `vgpukvm` allows to disable vgpu-kvm mode of host driver, basically
              switching it back to behavior of normal consumer desktop driver,
              particularly when using the "merged" variant of patched driver.

              This may be used to create secondary boot entry within bootloader
              in order to boot without vgpu support, allowing easy "switching"
              of nvidia driver without reinstall of any files.
            '';
          };
          kmalimit = lib.mkOption {
            type = types.int;
            default = 8192;
            description = ''
              This option is provided by vgpu-kvm-optional-vgpu-v2.patch.

              `kmalimit` is rather for testing, so do not use that unless
              you know what are you doing.
            '';
          };
          nvprnfilter = lib.mkOption {
            type = types.bool;
            default = false;
            description = ''
              Basic filter for nvrm logs, to be used with verbose nvrm logging
              for debugging, like for example:
              ``options nvidia NVreg_ResmanDebugLevel=0 nvprnfilter=1``
            '';
          };
          cudahost = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              This was used with older versions of the vgpu unlock patcher
              to experimentally enable cuda support on host with vgpu kvm merged
              driver - now this option defaults to 0 with not merged driver
              and to 1 with a merged one, so you can use it to disable cuda with
              merged driver in case of some problems.
            '';
          };
          vupdevid = lib.mkOption {
            type = types.int;
            default = 7728;
            description = ''
              This is mainly for testing override of pci devid, most of the time
              it does not need to be touched.
            '';
          };
          klogtrace = lib.mkOption {
            type = types.bool;
            default = false;
            description = ''
              This can be used to enable tracing of nvidia blob code, may be useful
              for development or for bugs analysis for example when comparing traces
              of a working case with a not working case.
            '';
          };
          klogtracefc = lib.mkOption {
            type = types.int;
            default = 8;
            description = ''
              Set the filter count for `klogtrace`.
            '';
          };
          vup_vgpusig = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Based on patch from mbuchel to disable vgpu config signature check.
            '';
          };
          vup_kunlock = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Kernel driver level method of vgpu unlock which does not need any
              ioctl hooks in userspace.
            '';
          };
          vup_merged = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Controls the patch to enable display output on host with merged driver.
            '';
          };
          vup_qmode = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to enable Quadro mode, which will cause Product Brand to be reported
              as Quadro when running `nvidia-smi -q`.
              It is better to enabled it to use Q profiles.
            '';
          };
          vup_sunlock = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Based on patch from LIL'pingu fixing xid 43 crashes when running
              vgpu with consumer cards (not needed when vup_kunlock is used).

              This option has been extended since 535.104 patcher branch with additional
              blob patches that substantially change the vgpu unlock method in the nvidia kernel driver.
              The new extension basically forces all GPUs to be marked as not supported for vgpu
              in the function that checks that based on pci devid official vgpu support list
              and compensates that in other places that would cause running vgpu to fail.
              This seems to somehow influence the performance significantly, as the stuttering
              of heavy games like FH5 is eliminated in this mode.

              No idea what side effects this could have. Even officially vgpu supported
              cards now would be in unsupported mode with the new blob patches to unlock them. 
            '';
          };
          vup_fbcon = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to prevent nvidia driver to use vram originally reserved for efifb,
              keeping efifb console working.
              This implies slightly different capacity of vram available for nvidia comparing
              these two cases, by the size that efifb needs when working.
            '';
          };
          vup_gspvgpu = lib.mkOption {
            type = types.bool;
            default = false;
            description = ''
              [Experimental] Added in 535.54.03, this option will force use of GSP firmware
              in vgpu mode. This seems to move profiles validation from kernel driver to GSP,
              so the signature check kernel patch seems not to be effective anymore.

              Should be used with --spoof-devid patcher option.
            '';
          };
          vup_swrlwar = lib.mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable this option with merged driver, otherwise starting a VM
              from xorg will fail with errors as described here:
              https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher/commit/9a5aa99de9e611bdeacd52c2ae79f800967f2c5e

              With the option enabled, that error is ignored - the function
              still fails to change the "software runlist max count", but with
              the workaround it is ignored and not even logged.

              We can only guess here, what side effects that may have.
            '';
          };
        };
        copyVGPUProfiles = mkOption {
          type = types.attrs;
          default = {};
          example = {
            "5566:7788" = "1122:3344";
          };
          description = ''
            Adds vcfgclone lines to the patcher. For more information, see the vGPU-Unlock-Patcher README.
            The value in the example above is equivalent to vcfgclone 0x1122 0x3344 0x5566 0x7788.
          '';
        };
        profileOverrides = mkOption {
          type = (types.attrsOf (types.submodule {
            options = {
              vramAllocation = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "vRAM allocation in megabytes. `profileSize`, `framebuffer` and `fbReservation` will be calculated automatically.";
              };
              heads = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Maximum allowed virtual monitors (heads).";
              };
              enableCuda = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = "Whenether to enable CUDA support.";
              };
              display.width = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Display width in pixels. `maxPixels` will be calculated automatically.";
              };
              display.height = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Display height in pixels. `maxPixels` will be calculated automatically.";
              };
              framerateLimit = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Cap FPS to specific value. `0` will disable limit.";
              };
              xmlConfig = mkOption {
                type = types.attrs;
                default = {};
                example = {
                  eccSupported = "1";
                  license = "NVS";
                };
                description = ''
                  Additional XML configuration.
                  `{ a = "b"; }` is equal to `<a>b</a>`, `{ a = { b = "d"; c = "e"; }; }` is equal to `<a b="d" c="e"/>`.
                '';
              };
            };
          }));
          default = {};
          description = "Allows to edit vGPU profiles' properties like vRAM allocation, maximum display size, etc.";
        };
        enablePatcherCmd = mkOption {
          type = types.bool;
          default = false;
          description = "Adds the vGPU-Unlock-patcher script (renamed to nvidia-vup) to environment.systemPackages for convenience.";
        };
      };
    };
  };
  config = mkMerge [
    (mkIf (builtins.hasAttr "vgpuPatcher" nvidiaCfg.package) {
      systemd.services.nvidia-vgpud = {
        description = "NVIDIA vGPU Daemon";
        wants = [ "syslog.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "forking";
          ExecStart = "${lib.getBin nvidiaCfg.package}/bin/nvidia-vgpud";
          ExecStopPost = "${pkgs.coreutils}/bin/rm -rf /var/run/nvidia-vgpud";
        };
        restartIfChanged = false;
      };
      systemd.services.nvidia-vgpu-mgr = {
        description = "NVIDIA vGPU Manager Daemon";
        wants = [ "syslog.target" ];
        wantedBy = [ "multi-user.target" ];
        requires = [ "nvidia-vgpud.service" ];
        after = [ "nvidia-vgpud.service" ];
        serviceConfig = {
          Type = "forking";
          KillMode = "process";
          ExecStart = "${lib.getBin nvidiaCfg.package}/bin/nvidia-vgpu-mgr";
          ExecStopPost = "${pkgs.coreutils}/bin/rm -rf /var/run/nvidia-vgpu-mgr";
        };
        restartIfChanged = false;
      };
      systemd.services.nvidia-xid-logd = {
        enable = false; # disabled by default
        description = "NVIDIA Xid Log Daemon";
        wantedBy = [ "multi-user.target" ];
        after = [ "nvidia-vgpu-mgr.service" ];
        serviceConfig = {
          Type = "forking";
          ExecStart = "${lib.getBin nvidiaCfg.package}/bin/nvidia-xid-logd";
          RuntimeDirectory = "nvidia-xid-logd";
        };
        restartIfChanged = false;
      };

      environment.systemPackages = lib.optional (nvidiaCfg.vgpu.patcher.enablePatcherCmd) nvidiaCfg.package.vgpuPatcher;

      environment.etc."nvidia/vgpu/vgpuConfig.xml".source =
        (if nvidiaCfg.vgpu.patcher.enable && nvidiaCfg.vgpu.patcher.profileOverrides != {}
        then
          (pkgs.runCommand "vgpuconfig-override" { nativeBuildInputs = [ pkgs.xmlstarlet ]; } ''
            mkdir -p $out
            ${xmlstarletCmd} ${nvidiaCfg.package + /vgpuConfig.xml} > $out/vgpuConfig.xml
          '')
        else
          nvidiaCfg.package) + /vgpuConfig.xml;
      
      boot.extraModprobeConfig = lib.optionalString (nvidiaCfg.vgpu.patcher.runtimeOptions.enable) ("options nvidia " +
        "vgpukvm=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vgpukvm then "1" else "0"} " +
        "kmalimit=${builtins.toString nvidiaCfg.vgpu.patcher.runtimeOptions.kmalimit} " +
        "nvprnfilter=${if nvidiaCfg.vgpu.patcher.runtimeOptions.nvprnfilter then "1" else "0"} " +
        "cudahost=${if nvidiaCfg.vgpu.patcher.runtimeOptions.cudahost then "1" else "0"} " +
        "vupdevid=${builtins.toString nvidiaCfg.vgpu.patcher.runtimeOptions.vupdevid} " +
        "klogtrace=${if nvidiaCfg.vgpu.patcher.runtimeOptions.klogtrace then "1" else "0"} " +
        "klogtracefc=${builtins.toString nvidiaCfg.vgpu.patcher.runtimeOptions.klogtracefc} " +
        "vup_vgpusig=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_vgpusig then "1" else "0"} " +
        "vup_kunlock=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_kunlock then "1" else "0"} " +
        "vup_merged=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_merged then "1" else "0"} " +
        "vup_qmode=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_qmode then "1" else "0"} " +
        "vup_sunlock=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_sunlock then "1" else "0"} " +
        "vup_fbcon=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_fbcon then "1" else "0"} " +
        "vup_gspvgpu=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_gspvgpu then "1" else "0"} " +
        "vup_swrlwar=${if nvidiaCfg.vgpu.patcher.runtimeOptions.vup_swrlwar then "1" else "0"} " +
        "");
    })

    # The absence of the "nvidia" element in the config.services.xserver.videoDrivers option (to use non-merged drivers in our case)
    # will result in the driver not being installed properly without this fix
    (mkIf ((builtins.hasAttr "vgpuPatcher" nvidiaCfg.package) && !(lib.elem "nvidia" config.services.xserver.videoDrivers)) {
      boot = {
        blacklistedKernelModules = [ "nouveau" "nvidiafb" ];
        extraModulePackages = [ nvidiaCfg.package.bin ]; # TODO: nvidia-open support
        kernelModules = [ "nvidia" "nvidia-vgpu-vfio" ];
      };
      environment.systemPackages = [ nvidiaCfg.package.bin ];

      # taken from nixpkgs
      systemd.tmpfiles.rules = lib.mkIf config.virtualisation.docker.enableNvidia [ "L+ /run/nvidia-docker/bin - - - - ${nvidiaCfg.package.bin}/origBin" ];
    })
  ];
}
