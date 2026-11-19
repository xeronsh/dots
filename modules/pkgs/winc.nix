# Winc：Rust 原生代码编辑器（https://winc.si）。
# 上游只提供 AppImage / deb / Arch 源，这里解包 AppImage 后直接运行 usr/bin/winc：
# 该二进制只硬依赖 glibc，Wayland / X11 / xkbcommon 均为 dlopen，
# 因此用 makeWrapper 给一个 LD_LIBRARY_PATH 即可，不需要 FHS 环境。
{ pkgs }:
let
  version = "0.1.688";
  src = pkgs.fetchurl {
    url = "https://winc.si/releases/Winc-${version}-linux-x64.AppImage";
    hash = "sha256-fy/9sg2DzwTVBn+MVuXgcmJ+7qQmwwMrVmMRCbesPNE=";
  };
  appimageContents = pkgs.appimageTools.extract {
    pname = "winc";
    inherit version src;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "winc";
  inherit version;

  src = appimageContents;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/winc
    cp -r usr $out/opt/winc/

    install -Dm644 winc.desktop $out/share/applications/winc.desktop
    install -Dm644 usr/share/icons/hicolor/256x256/apps/winc.png \
      $out/share/icons/hicolor/256x256/apps/winc.png

    makeWrapper $out/opt/winc/usr/bin/winc $out/bin/winc \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [
          pkgs.wayland
          pkgs.libxkbcommon
          pkgs.xorg.libX11
          pkgs.xorg.libXcursor
          pkgs.xorg.libXi
          pkgs.xorg.libxcb
        ]}

    runHook postInstall
  '';

  meta = {
    description = "A lighter, faster desktop code editor";
    homepage = "https://winc.si";
    license = pkgs.lib.licenses.asl20;
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "winc";
  };
}

