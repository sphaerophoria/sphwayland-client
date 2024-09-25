with import <nixpkgs> {};

let
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/8001cc402f61b8fd6516913a57ec94382455f5e5.tar.gz")
    # reuse the current configuration
    { config = config; };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; with xorg; [
    unstable.zls
    unstable.zig_0_13
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

