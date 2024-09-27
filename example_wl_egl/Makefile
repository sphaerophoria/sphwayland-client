all: server client

xdg_shell.c: xdg-shell.xml
	wayland-scanner private-code xdg-shell.xml xdg-shell.c

xdg_shell.h: xdg-shell.xml
	wayland-scanner client-header xdg-shell.xml xdg-shell.h

client: client.c egl-on-wayland-xdg.c xdg_shell.c xdg_shell.h
	zig cc -o client client.c xdg-shell.c -lwayland-egl -lwayland-client -lEGL -lGL -lGLEW

server: server.c xdg_shell.c xdg_shell.h egl-on-wayland-xdg.c
	zig cc -o server server.c xdg-shell.c -lwayland-egl -lwayland-client -lEGL -lGL -lGLEW
