# FlClash 0.9.3（上游最新）— nixpkgs 26.05 只有 0.8.92，unstable 已移除该包，
# 因此直接解包上游 Linux .deb（Flutter 已编译产物），用 autoPatchelf 修好动态库路径。
{ pkgs }:
let
  version = "0.9.3";
in
pkgs.stdenv.mkDerivation {
  pname = "flclash";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/chen08209/FlClash/releases/download/v${version}/FlClash-${version}-linux-amd64.deb";
    hash = "sha256-QGQlQym7OcYonHQ+FuVyauVrWFPobZ+I4BReKvAyNRs=";
  };

  nativeBuildInputs = with pkgs; [
    dpkg
    autoPatchelfHook
    makeWrapper
    imagemagick
  ];

  buildInputs = with pkgs; [
    gtk3
    glib
    libepoxy
    keybinder3
    libayatana-appindicator
    libsecret
    stdenv.cc.cc.lib
  ];

  autoPatchelfIgnoreMissingDeps = [ "libjvm.so" ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/opt $out/bin $out/share
    cp -r opt/FlClash $out/opt/FlClash
    cp -r usr/share/applications $out/share/
    cp -r usr/share/icons $out/share/
    makeWrapper $out/opt/FlClash/FlClash $out/bin/FlClash \
      --prefix LD_LIBRARY_PATH : "$out/opt/FlClash/lib"
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Proxy client based on ClashMeta, simple and easy to use";
    homepage = "https://github.com/chen08209/FlClash";
    license = licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "FlClash";
  };
}
