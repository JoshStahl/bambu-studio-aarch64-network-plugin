#!/bin/bash
# Bambu Studio aarch64 Network Plugin Installer
# Builds bambu-farm from source and installs it as the network plugin
# for the Bambu Studio Flatpak on aarch64 Linux (tested on Asahi Linux / Fedora).
#
# Usage: bash install.sh
# Re-run after Bambu Studio updates to restore the plugin.

set -e

BAMBU_STUDIO_VERSION="$(flatpak info com.bambulab.BambuStudio 2>/dev/null | grep Version | awk '{print $2}')"
PLUGIN_DIR="$HOME/.var/app/com.bambulab.BambuStudio/config/BambuStudio/plugins"
BUILD_DIR="/tmp/bambu-farm"
INSTALL_DIR="$HOME/bambu-farm"

# ── Helpers ────────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1 — install it and re-run."
}

# ── Preflight ──────────────────────────────────────────────────────────────────

info "Checking architecture..."
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || die "This script is for aarch64 systems only (detected: $ARCH)"

info "Checking Bambu Studio Flatpak..."
flatpak info com.bambulab.BambuStudio &>/dev/null || die "Bambu Studio Flatpak not installed. Install it first."

require_cmd git
require_cmd gcc
require_cmd g++
require_cmd make
require_cmd ar
require_cmd flatpak

info "Detected Bambu Studio version: $BAMBU_STUDIO_VERSION"

# Convert "2.5.0.66" → "02.05.00.66"
format_version() {
    IFS='.' read -r a b c d <<< "$1"
    printf "%02d.%02d.%02d.%02d" "$a" "$b" "$c" "$d"
}
PLUGIN_VERSION="$(format_version "$BAMBU_STUDIO_VERSION")"
info "Plugin will report version: $PLUGIN_VERSION"

# ── Install system dependencies ────────────────────────────────────────────────

info "Installing system dependencies (requires sudo)..."
if command -v dnf &>/dev/null; then
    sudo dnf install -y protobuf-compiler msgpack-devel openssl-devel gcc g++ make
elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y protobuf-compiler libmsgpack-dev libssl-dev build-essential
else
    warn "Unknown package manager — ensure these are installed: protoc, msgpack C++ headers, openssl-devel, gcc, g++"
fi

# ── Install Rust ───────────────────────────────────────────────────────────────

if ! command -v cargo &>/dev/null && [ ! -f "$HOME/.cargo/env" ]; then
    info "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env" 2>/dev/null || true
command -v cargo &>/dev/null || die "Rust/cargo not found after install."
info "Rust version: $(rustc --version)"

# ── Clone bambu-farm ───────────────────────────────────────────────────────────

if [ -d "$BUILD_DIR" ]; then
    info "Updating existing bambu-farm clone..."
    git -C "$BUILD_DIR" pull --ff-only 2>/dev/null || warn "Could not pull latest — using existing source."
else
    info "Cloning bambu-farm..."
    git clone https://github.com/ellenhp/bambu-farm.git "$BUILD_DIR"
fi

# ── Patch paho-mqtt for GCC 15 (C23 bool keyword conflict) ────────────────────

PAHO_HEADER="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/paho-mqtt-sys-0.9.0/paho.mqtt.c/src/MQTTPacket.h"
if [ -f "$PAHO_HEADER" ] && grep -q "^typedef unsigned int bool;" "$PAHO_HEADER"; then
    info "Patching paho-mqtt for GCC 15 C23 compatibility..."
    sed -i 's/^typedef unsigned int bool;$/#if !defined(__cplusplus) \&\& (!defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L)\ntypedef unsigned int bool;\n#endif/' "$PAHO_HEADER"
    # Clear cmake cache so the patched source is picked up
    rm -rf "$BUILD_DIR/bambu-farm-server/target/debug/build/paho-mqtt-sys-"*/
fi

# ── Patch the plugin version to match installed Bambu Studio ──────────────────

info "Setting plugin version to $PLUGIN_VERSION ..."
VERSION_FILE="$BUILD_DIR/bambu-farm-client/cpp/bambu_networking.hpp"
sed -i "s/#define BAMBU_NETWORK_AGENT_VERSION \"[^\"]*\"/#define BAMBU_NETWORK_AGENT_VERSION \"$PLUGIN_VERSION\"/" "$VERSION_FILE"
grep "BAMBU_NETWORK_AGENT_VERSION" "$VERSION_FILE"

# ── Build ──────────────────────────────────────────────────────────────────────

info "Building bambu-farm client..."
cd "$BUILD_DIR/bambu-farm-client"
cargo build --quiet

info "Assembling shared library..."
mkdir -p target/debug/shared
cd target/debug/shared
rm -f ./*.o
ar -x ../libbambu_farm_client.a
g++ -shared ./*.o -o libbambu_networking.so -lstdc++ -lgcc_s
echo "" | gcc -fPIC -shared -x c -o libBambuSource.so -

info "Building bambu-farm server..."
cd "$BUILD_DIR/bambu-farm-server"
cargo build --quiet

# ── Install server binary and config ──────────────────────────────────────────

info "Installing server to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cp "$BUILD_DIR/bambu-farm-server/target/debug/bambu-farm-server" "$INSTALL_DIR/"

# Only create config if one doesn't already exist
if [ ! -f "$INSTALL_DIR/bambufarm.toml" ]; then
    cp "$(dirname "$0")/bambufarm.toml" "$INSTALL_DIR/bambufarm.toml"
    info "Created config at $INSTALL_DIR/bambufarm.toml — edit it to add your printer."
else
    info "Config already exists at $INSTALL_DIR/bambufarm.toml — not overwriting."
fi

# Also place config in home dir (Flatpak working directory fallback)
if [ ! -f "$HOME/bambufarm.toml" ]; then
    cp "$INSTALL_DIR/bambufarm.toml" "$HOME/bambufarm.toml"
fi

# ── Install plugin files ───────────────────────────────────────────────────────

info "Installing plugin to $PLUGIN_DIR ..."
sudo chattr -i "$PLUGIN_DIR/libbambu_networking.so" "$PLUGIN_DIR/libBambuSource.so" 2>/dev/null || true
cp "$BUILD_DIR/bambu-farm-client/target/debug/shared/libbambu_networking.so" "$PLUGIN_DIR/"
cp "$BUILD_DIR/bambu-farm-client/target/debug/shared/libBambuSource.so" "$PLUGIN_DIR/"
# Lock files so Bambu Studio can't overwrite them on update
sudo chattr +i "$PLUGIN_DIR/libbambu_networking.so" "$PLUGIN_DIR/libBambuSource.so"

info "Verifying plugin architecture..."
file "$PLUGIN_DIR/libbambu_networking.so" | grep -q "aarch64" || die "Plugin is not aarch64!"
echo "  OK: $(file "$PLUGIN_DIR/libbambu_networking.so")"

# ── Set up systemd user service ────────────────────────────────────────────────

info "Installing systemd user service..."
mkdir -p "$HOME/.config/systemd/user"
cp "$(dirname "$0")/bambu-farm-server.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now bambu-farm.service

sleep 2
if systemctl --user is-active --quiet bambu-farm.service; then
    info "bambu-farm server is running."
else
    warn "bambu-farm server failed to start. Check: journalctl --user -u bambu-farm.service"
    warn "Most likely cause: printer not configured in $INSTALL_DIR/bambufarm.toml"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Installation complete!"
echo ""
echo " Next steps:"
echo "   1. Edit $INSTALL_DIR/bambufarm.toml"
echo "      Add your printer's IP, serial number, and access code."
echo ""
echo "   2. Restart the server after editing config:"
echo "      systemctl --user restart bambu-farm.service"
echo ""
echo "   3. Open Bambu Studio — the network plugin should now work."
echo ""
echo " NOTE: After any Bambu Studio update, re-run this script"
echo "       to reinstall the aarch64 plugin."
echo "════════════════════════════════════════════════════════════"
