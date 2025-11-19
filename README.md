<p align="center">
  <img src="https://github.com/thecalamityjoe87/paperboy/blob/main/data/icons/256x256/paperboy.png?raw=true"/>
</p>

# **Paperboy**

![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot1.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot2.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot3.png?raw=true "Optional Title")

## About
A simple news app written in Vala, built with GTK4 and Libadwaita. My motivation for building this app because I wanted to have a simple, but beautiful native GTK4 news application similar to Apple News. Feel free to test, change, and contribute back to this project.

Some cool features of Paperboy:

- **Ships with curated sources** like The Guardian, Reddit, BBC, and FOX News.
- **Fetches articles through PaperboyAPI**, a custom API that aggregates news from multiple sources and categories.
- **Lets you build a custom feed** by combining any sources and categories you want.
- **Includes local news support**, so you can see what’s happening near you.

### --Warning--
This app is very much so in an alpha state. It will definitely eat your dogs and throw your kittens outside. It's functional, but it's still very much so a WIP.

## Build dependencies
This project declares several dependencies in `meson.build` (gtk4, libadwaita, libsoup, json-glib, gdk-pixbuf, libxml2, gee) plus the Vala toolchain and the usual build tools (Meson, Ninja, a C compiler and pkg-config).

Common distro install commands are provided below.
- Vala compiler and toolchain: valac
- Meson & Ninja: meson, ninja
- GTK4 development headers: libgtk-4-dev
- Libsoup dev (2.4): libsoup2.4-dev
- JSON-GLib dev: libjson-glib-dev

## Building
Common distro install commands:

Debian / Ubuntu:

```bash
sudo apt update
sudo apt install build-essential valac meson ninja-build pkg-config \
	libgtk-4-dev libadwaita-1-dev libsoup2.4-dev libjson-glib-dev \
	libgdk-pixbuf2.0-dev libxml2-dev libgee-0.8-dev
```

Fedora:

```bash
sudo dnf install @development-tools vala meson ninja pkgconf-pkg-config \
	gtk4-devel libadwaita-devel libsoup-devel json-glib-devel \
	gdk-pixbuf2-devel libxml2-devel gee-devel
```

Arch Linux:

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

## Installing system-wide (optional)

```bash
# from the project root
sudo ninja -C build install
```



