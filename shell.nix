with import <nixpkgs> {};
let
unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/f73d4f0ad010966973bc81f51705cef63683c2f2.tar.gz") {};
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; with xorg; [
    unstable.zls
    unstable.zig
    gdb
    valgrind
    python3
    pkg-config
    expat
    clang-tools
    wayland
    wayland-protocols
    libGL
    mesa
    libgbm
    libdrm
    libinput
    systemd
  ];
}

