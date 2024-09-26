test:

xdg_shell.c: xdg-shell.xml
	wayland-scanner private-code xdg-shell.xml xdg-shell.c

xdg_shell.h: xdg-shell.xml
	wayland-scanner client-header xdg-shell.xml xdg-shell.h

test: xdg_shell.c xdg_shell.h egl-on-wayland-xdg.c
	zig cc -o test xdg-shell.c egl-on-wayland-xdg.c -lwayland-egl -lwayland-client -lEGL -lGL -lGLEW
