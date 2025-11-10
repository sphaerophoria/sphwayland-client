#!/usr/bin/env python3

import subprocess
import signal
import time
import sys
import random


# Not that kind of window manager
class WindowManager:
    def __init__(self):
        self.windows = []

    def closeAll(self):
        self.closeFrom(0)

    def closeFrom(self, idx):
        if idx >= len(self.windows):
            return

        for process in self.windows[idx:]:
            process.send_signal(signal.SIGINT)

        self.windows = self.windows[0:idx]

    def step(self):
        new_num_windows = random.randint(0, 10)
        print("this many windows now man", new_num_windows)
        self.closeFrom(new_num_windows)
        for _ in range(len(self.windows), new_num_windows):
            self.makeWindow()

    def makeWindow(self):
        self.windows.append(
            subprocess.Popen(
                ["./zig-out/bin/sphwayland-client"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        )


class SignalHandler:
    def __init__(self, windows):
        self.windows = windows

    def __call__(self, sig, frame):
        # Close all windows before exiting
        self.windows.closeAll()
        sys.exit(0)


def main():
    windows = WindowManager()
    signal.signal(signal.SIGINT, SignalHandler(windows))

    while True:
        time.sleep(0.5)
        windows.step()


if __name__ == "__main__":
    main()
