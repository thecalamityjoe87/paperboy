<p align="center">
  <img src="https://github.com/thecalamityjoe87/paperboy/blob/main/data/icons/256x256/paperboy.png?raw=true"/>
</p>

# **Paperboy (Vala + GTK)**

![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot.png?raw=true "Optional Title")

A simple Vala/GTK news app. See the Build dependencies section below for distro-specific install commands.

Build dependencies
This project declares several dependencies in `meson.build` (gtk4, libadwaita, libsoup, json-glib, gdk-pixbuf, libxml2, gee) plus the Vala toolchain and the usual build tools (Meson, Ninja, a C compiler and pkg-config).

Common distro install commands are provided below.
- Vala compiler and toolchain: valac
- Meson & Ninja: meson, ninja
- GTK4 development headers: libgtk-4-dev
- Libsoup dev (2.4): libsoup2.4-dev
- JSON-GLib dev: libjson-glib-dev


Common distro install commands

Debian / Ubuntu (example):

```bash
sudo apt update
sudo apt install build-essential valac meson ninja-build pkg-config \
	libgtk-4-dev libadwaita-1-dev libsoup2.4-dev libjson-glib-dev \
	libgdk-pixbuf2.0-dev libxml2-dev libgee-0.8-dev
```

Fedora (example):

```bash
sudo dnf install @development-tools vala meson ninja pkgconf-pkg-config \
	gtk4-devel libadwaita-devel libsoup-devel json-glib-devel \
	gdk-pixbuf2-devel libxml2-devel gee-devel
```

Arch Linux (example):

```bash
sudo pacman -S --needed base-devel vala meson ninja pkgconf \
	gtk4 libadwaita libsoup json-glib gdk-pixbuf2 libxml2 gee
```

Build & run

```bash
# configure build dir (only once)
meson setup build

# compile
meson compile -C build

# run the built binary
./build/paperboy
```

Install system-wide (optional)

```bash
# from the project root
sudo ninja -C build install
```


