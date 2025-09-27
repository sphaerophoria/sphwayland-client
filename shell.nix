with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; with xorg; [
    zls
    zig_0_13
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
  ];
}

