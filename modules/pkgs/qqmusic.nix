# 腾讯官方 QQ 音乐 Linux 客户端（1.1.4 AppImage 重打包）。
# 官方 1.1.8 的 deb 下载链接当前被腾讯 COS 置为归档态（403 InvalidObjectState），
# 等上游恢复后可换成 nixpkgs 的 pkgs.qqmusic。
{ pkgs }:

let
  version = "1.1.4";

  src = pkgs.fetchurl {
    url = "https://github.com/gasuncom/AppImage/releases/download/AppImage/Tencent-QQMusic-v${version}-x86_64.AppImage";
    hash = "sha256-DKRU+0pXAhP/KChcJ43l3yI49leFD8o8nmx2a2Ogy7E=";
  };

  app = pkgs.appimageTools.wrapType2 {
    pname = "qqmusic";
    inherit version src;
    extraPkgs = p: [ p.libpulseaudio p.noto-fonts-cjk-sans ];
  };

  extracted = pkgs.appimageTools.extract {
    pname = "qqmusic-icon";
    inherit version src;
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "qqmusic";
    desktopName = "QQ音乐";
    genericName = "Music Player";
    exec = "qqmusic %U";
    icon = "qqmusic";
    comment = "腾讯QQ音乐";
    categories = [ "AudioVideo" "Audio" ];
    startupWMClass = "qqmusic";
  };
in
pkgs.symlinkJoin {
  name = "qqmusic-${version}";
  paths = [ app ];
  postBuild = ''
    mkdir -p $out/share/applications $out/share/icons/hicolor/256x256/apps
    cp ${desktopItem}/share/applications/qqmusic.desktop $out/share/applications/qqmusic.desktop
    cp ${extracted}/qqmusic.png $out/share/icons/hicolor/256x256/apps/qqmusic.png
  '';
  meta = {
    description = "Tencent QQ Music (official Linux client, AppImage repack)";
    homepage = "https://y.qq.com/";
    platforms = [ "x86_64-linux" ];
    license = pkgs.lib.licenses.unfree;
    mainProgram = "qqmusic";
  };
}
