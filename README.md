<p align="center">
  <img src="https://github.com/thecalamityjoe87/paperboy/blob/main/data/icons/256x256/paperboy.png?raw=true"/>
</p>

# **Paperboy**

![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot1.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot2.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot3.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot4.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot5.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot6.png?raw=true "Optional Title")
![Alt text](https://github.com/thecalamityjoe87/paperboy/blob/main/images/screenshot7.png?raw=true "Optional Title")

## About
A simple news app written in Vala, built with GTK4 and Libadwaita. My motivation for building this app because I wanted to have a simple, but beautiful native GTK4 news application similar to Apple News. Feel free to test, change, and contribute back to this project.

## 🚀 Some cool features of Paperboy

- 📰 **Curated sources out of the box** – including The Guardian, Reddit, BBC, and FOX News.  
- ⚡ **Powered by PaperboyAPI** – fetches articles from multiple sources and categories seamlessly.  
- ⭐ **Follow news sources** – users can add sources they find through the API.  
- 📡 **RSS feed support** – add any RSS feeds to Paperboy to follow additional websites or blogs.  
- 🛠️ **Customizable feeds** – mix and match sources and categories to create your own personalized news stream.  
- 📖 **In-app article viewing** – read articles without leaving the app.  
- 🌍 **Local news support** – stay updated on what’s happening in your area.

### WARNING
This app is very much so in an alpha state. It will definitely eat your dogs and throw your kittens outside. It's functional, but it's still very much so a WIP.

## Build dependencies
This project declares several dependencies in `meson.build` (GTK4, Libadwaita, libsoup-3.0, JSON-GLib, GdkPixbuf, libxml2, Gee, WebKitGTK) plus the Vala toolchain and the usual build tools (Meson, Ninja, a C compiler and `pkg-config`).

Additionally, the repository contains a small Rust helper (`tools/html2rss`) that is built with Cargo during the Meson configure step. To produce AppImages you will also need `appimagetool` (or the AppImage bundle of `appimagetool`).

Summary of required toolchain and libraries:
- Vala compiler and toolchain: `valac`
- Meson & Ninja: `meson`, `ninja-build` (or `ninja`)
- GTK4 development headers and Libadwaita: `libgtk-4-dev`, `libadwaita-1-dev`
- WebKitGTK (for embedded web view): `libwebkitgtk-6.0` development headers
- Libsoup 3 (HTTP client used by the app): `libsoup-3.0` development headers
- JSON-GLib: `libjson-glib-dev`
- GdkPixbuf: `libgdk-pixbuf2.0-dev`
- libxml2: `libxml2-dev`
- Gee collection library: `libgee-0.8-dev`
- SQLite (runtime and headers): `libsqlite3-dev`
- Rust toolchain (Cargo) for building `tools/html2rss` (recommended install via `rustup`)
- `appimagetool` (optional, to create AppImages)

Package names can vary between distributions. Example install commands for a few distros follow; adjust package names if your distribution uses slightly different names for WebKitGTK or libsoup-3.0.

## Building
Common distro install commands:

Debian / Ubuntu:

```bash
sudo apt update
sudo apt install build-essential valac meson ninja-build pkg-config \
	libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev \
	libsoup3.0-dev libjson-glib-dev libgdk-pixbuf-2.0-dev \
	libxml2-dev libgee-0.8-dev libsqlite3-dev

# Rust (recommended via rustup) and appimagetool (optional):
sudo apt install curl
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo apt install appimagetool || true
```

Fedora:

```bash
sudo dnf install @development-tools vala meson ninja pkgconf-pkg-config \
  gtk4-devel libadwaita-devel webkitgtk6-devel libsoup3-devel json-glib-devel \
  gdk-pixbuf2-devel libxml2-devel libgee-devel sqlite-devel

# Rust toolchain and appimagetool (if desired):
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
# appimagetool on Fedora can be downloaded from AppImage releases
```

Arch Linux:

```bash
sudo pacman -S --needed base-devel vala meson ninja pkgconf \
  gtk4 libadwaita webkit2gtk libsoup json-glib gdk-pixbuf2 libxml2 gee sqlite

# Rust and appimagetool (optional):
rustup default stable
pacman -S appimagetool || true
```

OpenSUSE Tumbleweed:
```bash
sudo zypper in -t pattern devel_basis && sudo zypper in meson vala gtk4-devel \
  libwebkitgtk6.0-devel libsoup3-devel json-glib-devel libadwaita-devel libgee-devel sqlite3-devel
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

Notes:
- Meson will attempt to build `tools/html2rss` with Cargo during configure; ensure `cargo` is available on PATH or the html2rss helper won't be built/installed.
- To produce an AppImage, run `./packaging/appimage/build-appimage.sh`. That script will try to use `appimagetool` from PATH or a bundled `appimagetool-x86_64.AppImage` if present.
## Installing system-wide (optional)

```bash
# from the project root
sudo ninja -C build install
```



