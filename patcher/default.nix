{ pkgs, lib, version ? "custom", rev, sha256, vgpuDriver,
  merged ? false, fetchGuests ? false,
  generalSha256, generalVersion,
  linuxSha256, linuxGuest,
  windowsSha256, windowsGuestFilename,
  gridVersion, extraVGPUProfiles,
  generalUrl ? "https://download.nvidia.com/XFree86/Linux-x86_64/${generalVersion}",
  vgpuUrl ? "https://storage.googleapis.com/nvidia-drivers-us-public/GRID/vGPU${gridVersion}"
  }:

let
  buildInputs = with pkgs; [
    bash
    coreutils
    gnupatch
    gawk
    patchelf
    zstd # compression for --repack'd installers
    gcc
  ] ++ lib.optionals fetchGuests [
    p7zip
    mscompress
    mono # test signing for WSYS dlls
    osslsigncode
  ];
  # TODO: Use "nvidia-vup vcfg" instead of sed command
  vgpuProfileCmds = lib.attrsets.foldlAttrs (s: n: v:
    (s + "    vcfgclone \\\${TARGET}\\/vgpuConfig.xml "
    + "0x${builtins.substring 0 4 v} 0x${builtins.substring 5 4 v} "
    + "0x${builtins.substring 0 4 n} 0x${builtins.substring 5 4 n}\\n"))
    "" extraVGPUProfiles;
  # Hacky way to get file extension
  isVGPUInZip = lib.hasSuffix ".zip" (builtins.toString vgpuDriver);
in
pkgs.stdenv.mkDerivation {
  pname = "vgpu-unlock-patcher";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "MakiseKurisu";
    repo = "vGPU-Unlock-patcher";
    fetchSubmodules = true;
    inherit rev sha256;
  };

  driverSrcs = ([
      vgpuDriver
  ] ++ lib.optionals (merged || fetchGuests) [
    # General driver
    (pkgs.fetchurl {
      url = "${generalUrl}/NVIDIA-Linux-x86_64-${generalVersion}.run";
      sha256 = generalSha256;
    })
  ] ++ lib.optionals (fetchGuests && !isVGPUInZip) [
    # Windows guest driver
    (pkgs.fetchurl {
      url = "${vgpuUrl}/${windowsGuestFilename}";
      sha256 = windowsSha256;
    })
    # Linux guest driver
    (pkgs.fetchurl {
      url = "${vgpuUrl}/NVIDIA-Linux-x86_64-${linuxGuest}-grid.run";
      sha256 = linuxSha256;
    })
  ]);

  inherit buildInputs;
  nativeBuildInputs = with pkgs; [ makeWrapper unzip ];

  patches = [
    ./binaries-in-patcher-root.patch
    ./fix-basedir.patch
  ];
  # TODO: use nvidia-vup vcfg instead of sed
  installPhase = ''
    mkdir -p $out/bin
    cp -r ./ $out
    rm $out/nsigpatch.c

    patchShebangs $out/patch.sh
    sed -i '0,/^    vcfgclone \''${TARGET}\/vgpuConfig.xml /s//${vgpuProfileCmds}&/' $out/patch.sh
    ln -s $out/patch.sh $out/bin/nvidia-vup
    wrapProgram $out/bin/nvidia-vup \
      --prefix PATH : ${lib.makeBinPath buildInputs}

    # Copy drivers
    for i in $driverSrcs; do
      if [[ "$i" =~ \.zip$ ]]; then
        unzip -j $i "*."{run,exe} -d $out
      else
        cp $i $out/"$(stripHash "$i")"
      fi
    done
    chmod 555 $out/*.run
  '' + lib.optionalString fetchGuests ''
    # Compile nsigpatch
    gcc -fshort-wchar ./nsigpatch.c -o $out/nsigpatch
    ln -s $out/nsigpatch $out/bin/nsigpatch
  '';

  meta.mainProgram = "nvidia-vup";
}
