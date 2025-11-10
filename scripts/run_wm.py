#!/usr/bin/env python3

import subprocess
import os
import sys
from pathlib import Path


def main():
    uid = os.getuid()

    initial_wl_sockets = set(Path(f"/run/user/{uid}/").glob("wayland-*"))
    with Path("sphwim.log").open("w") as f:
        subprocess.Popen(["./zig-out/bin/sphwim"], stdout=f, stderr=f)
    while True:
        current_wl_sockets = set(Path(f"/run/user/{uid}/").glob("wayland-*"))
        new_sockets = current_wl_sockets.difference(initial_wl_sockets)

        if len(new_sockets) > 1:
            print("Too many new wl sockets")
            sys.exit(1)

        if len(new_sockets) == 1:
            break

    new_socket = next(iter(new_sockets))
    new_display = new_socket.name
    os.environ["WAYLAND_DISPLAY"] = new_display

    with Path("waiter.log").open("w") as f:
        waiter_process = subprocess.Popen(
            ["./zig-out/bin/wait_for_wl"], stdout=f, stderr=f
        )
    waiter_process.wait()

    with Path("client1.log").open("w") as f:
        subprocess.Popen(["./zig-out/bin/sphwayland-client"], stdout=f, stderr=f)

    with Path("client2.log").open("w") as f:
        subprocess.Popen(["./zig-out/bin/sphwayland-client"], stdout=f, stderr=f)
        # subprocess.Popen(["./sphtud/src/gui/zig-out/bin/demo"], stdout=f, stderr=f)


if __name__ == "__main__":
    main()
