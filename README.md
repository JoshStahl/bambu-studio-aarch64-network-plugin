# Bambu Studio Network Plugin — aarch64 Linux Workaround

Bambu Lab's network plugin (`libbambu_networking.so`) is only officially distributed for **x86-64 Linux**. On aarch64 Linux — including Apple Silicon Macs running [Asahi Linux](https://asahilinux.org/) — Bambu Studio will download the wrong binary, fail to load it, and prompt you to install the plugin every time you launch.

This guide documents a working workaround using [bambu-farm](https://github.com/ellenhp/bambu-farm), an open-source reimplementation of the plugin interface that can be compiled natively for aarch64.

**Tested on:** Asahi Linux (Fedora Asahi Remix) on Apple M2 Max, Bambu Studio 2.5.0.66 (Flatpak), X1E printer.

> **Status of official support:** As of early 2026, Bambu Lab has acknowledged the issue ([GitHub #4658](https://github.com/bambulab/BambuStudio/issues/4658)) but has not released an aarch64 Linux plugin. Until they do, this workaround is the only option for LAN-mode printing.

---

## What This Does

- Builds [bambu-farm](https://github.com/ellenhp/bambu-farm) from source — a drop-in OSS replacement for `libbambu_networking.so`
- Installs the native aarch64 `.so` into the Bambu Studio Flatpak plugin directory
- Locks the file immutable so Bambu Studio can't overwrite it with the x86 binary on updates
- Runs a small gRPC backend server (the `bambu-farm-server`) as a systemd user service
- Enables LAN-mode printing, printer monitoring, and job submission

**What doesn't work yet** (bambu-farm limitation, not this guide): camera feed.

---

## Prerequisites

- aarch64 Linux (Fedora, Ubuntu, Debian, or any distro — tested on Fedora Asahi)
- Bambu Studio installed as a **Flatpak** (`com.bambulab.BambuStudio`)
- `sudo` access (needed to set the immutable file flag)
- Internet access to clone repos and download Rust crates

---

## Quick Install

```bash
git clone https://github.com/JoshStahl/bambu-studio-aarch64-network-plugin.git
cd bambu-studio-aarch64-network-plugin
bash install.sh
```

The script will:
1. Install system dependencies (protoc, msgpack headers, OpenSSL)
2. Install Rust via rustup (if not already installed)
3. Clone and build bambu-farm
4. Auto-detect your Bambu Studio version and set the plugin version to match
5. Install the plugin and lock it immutable
6. Set up and start the bambu-farm-server systemd service

---

## Configuration

After running `install.sh`, edit `~/bambu-farm/bambufarm.toml` to add your printer:

```toml
endpoint = "[::1]:47403"

printers = [
    { "name" = "My Printer", model = "x1c", "host" = "192.168.1.100", "dev_id" = "01XXXXXXX", "password" = "XXXXXXXX" }
]
```

| Field | Where to find it |
|---|---|
| `host` | Your printer's local IP — check your router's DHCP table or the printer's screen |
| `dev_id` | Serial number — shown in Bambu Studio's device list, or on the label on your printer |
| `password` | **Access Code** — on the printer touchscreen: Settings → WLAN |
| `model` | One of: `x1c`, `x1e`, `x1`, `p1p`, `p1s`, `a1`, `a1mini` |

After editing the config, restart the server:

```bash
systemctl --user restart bambu-farm.service
```

Then open Bambu Studio. The network plugin dialog should no longer appear.

---

## Manual Steps (if you prefer not to use the install script)

<details>
<summary>Click to expand step-by-step manual instructions</summary>

### 1. Install system dependencies

**Fedora / Asahi Linux:**
```bash
sudo dnf install -y protobuf-compiler msgpack-devel openssl-devel gcc g++ make git
```

**Ubuntu / Debian:**
```bash
sudo apt-get install -y protobuf-compiler libmsgpack-dev libssl-dev build-essential git
```

### 2. Install Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
```

### 3. Clone bambu-farm

```bash
git clone https://github.com/ellenhp/bambu-farm.git /tmp/bambu-farm
```

### 4. Patch paho-mqtt for GCC 15

GCC 15 defaults to C23, where `bool` is a reserved keyword. The version of paho-mqtt used by bambu-farm has a `typedef unsigned int bool;` that breaks compilation. Apply the fix:

```bash
PAHO_HEADER="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/paho-mqtt-sys-0.9.0/paho.mqtt.c/src/MQTTPacket.h"

# Build the client first so Cargo downloads paho-mqtt-sys:
cd /tmp/bambu-farm/bambu-farm-client && cargo build 2>/dev/null; true

# Then patch:
sed -i 's/^typedef unsigned int bool;$/#if !defined(__cplusplus) \&\& (!defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L)\ntypedef unsigned int bool;\n#endif/' "$PAHO_HEADER"

# Clear cmake cache:
rm -rf /tmp/bambu-farm/bambu-farm-server/target/debug/build/paho-mqtt-sys-*/
```

### 5. Set the plugin version to match your Bambu Studio

Bambu Studio rejects the plugin if its reported version doesn't start with the same `XX.XX.XX` prefix as the app. Check your version and set it:

```bash
# Get your Bambu Studio version (e.g. "2.5.0.66")
flatpak info com.bambulab.BambuStudio | grep Version

# Format it as zero-padded (e.g. "02.05.00.66") and update:
PLUGIN_VERSION="02.05.00.66"   # <-- change this to match your version
sed -i "s/#define BAMBU_NETWORK_AGENT_VERSION \"[^\"]*\"/#define BAMBU_NETWORK_AGENT_VERSION \"$PLUGIN_VERSION\"/" \
    /tmp/bambu-farm/bambu-farm-client/cpp/bambu_networking.hpp
```

**Version format:** `2.5.0.66` → `02.05.00.66`. Each component is zero-padded to 2 digits.

### 6. Build the client plugin

```bash
cd /tmp/bambu-farm/bambu-farm-client
cargo build

# Assemble the shared library
mkdir -p target/debug/shared && cd target/debug/shared
rm -f *.o
ar -x ../libbambu_farm_client.a

# IMPORTANT: use g++ (not gcc) to get the C++ runtime linked in
g++ -shared *.o -o libbambu_networking.so -lstdc++ -lgcc_s

# Create a stub for the second required library
echo "" | gcc -fPIC -shared -x c -o libBambuSource.so -
```

### 7. Build the server

```bash
cd /tmp/bambu-farm/bambu-farm-server
cargo build
```

### 8. Install the plugin

```bash
PLUGIN_DIR="$HOME/.var/app/com.bambulab.BambuStudio/config/BambuStudio/plugins"

# Remove immutable flag if previously set
sudo chattr -i "$PLUGIN_DIR/libbambu_networking.so" "$PLUGIN_DIR/libBambuSource.so" 2>/dev/null || true

cp /tmp/bambu-farm/bambu-farm-client/target/debug/shared/libbambu_networking.so "$PLUGIN_DIR/"
cp /tmp/bambu-farm/bambu-farm-client/target/debug/shared/libBambuSource.so "$PLUGIN_DIR/"

# Lock the files so Bambu Studio can't overwrite them on update
sudo chattr +i "$PLUGIN_DIR/libbambu_networking.so" "$PLUGIN_DIR/libBambuSource.so"

# Verify
file "$PLUGIN_DIR/libbambu_networking.so"
# Should show: ELF 64-bit LSB shared object, ARM aarch64
```

### 9. Set up the server

```bash
mkdir -p ~/bambu-farm
cp /tmp/bambu-farm/bambu-farm-server/target/debug/bambu-farm-server ~/bambu-farm/
cp bambufarm.toml ~/bambu-farm/bambufarm.toml   # from this repo
cp ~/bambu-farm/bambufarm.toml ~/bambufarm.toml  # Flatpak working directory fallback
```

Edit `~/bambu-farm/bambufarm.toml` with your printer's details (see Configuration section above).

### 10. Set up the systemd service

```bash
mkdir -p ~/.config/systemd/user
cp bambu-farm-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now bambu-farm.service

# Check it's running
systemctl --user status bambu-farm.service
```

</details>

---

## After a Bambu Studio Update

Bambu Studio updates will try to reinstall the x86 plugin. The immutable flag blocks this, but after a major version update you'll need to re-run the install script to update the version string:

```bash
bash install.sh
```

The script is idempotent — it detects your current Bambu Studio version automatically and rebuilds/reinstalls accordingly.

---

## Troubleshooting

**"Please install the network plugin" dialog still appears**

The plugin version doesn't match the app version. Re-run `install.sh` — it auto-detects the correct version string.

**bambu-farm service exits immediately**

Check the logs:
```bash
journalctl --user -u bambu-farm.service -n 30
```
Most likely your printer isn't configured yet in `~/bambu-farm/bambufarm.toml`.

**Plugin gets overwritten after Bambu Studio update**

Check that the immutable flag is still set:
```bash
lsattr ~/.var/app/com.bambulab.BambuStudio/config/BambuStudio/plugins/libbambu_networking.so
```
Should show `----i---` in the flags. If not, re-run `install.sh`.

**Server fails with "Expected printer field model to be one of..."**

Supported model values: `x1c`, `x1e`, `x1`, `p1p`, `p1s`, `a1`, `a1mini` (all lowercase). Check your `bambufarm.toml`.

**Camera feed doesn't work**

Not yet implemented in bambu-farm. This is a bambu-farm limitation, not this guide.

---

## How It Works

Bambu Studio uses `dlopen()` to load a network plugin at startup and calls into it for all cloud and LAN functionality. The plugin interface is a set of C-exported functions (`bambu_network_*`). Bambu Lab only distributes this plugin as a precompiled x86-64 binary for Linux.

[bambu-farm](https://github.com/ellenhp/bambu-farm) reimplements this same plugin interface in Rust + C++. Because it's built from source, it compiles natively for aarch64.

The architecture is two-process:
- **`libbambu_networking.so`** — loaded by Bambu Studio, communicates via gRPC to the server
- **`bambu-farm-server`** — handles MQTT, FTP, and TLS connections to the printer (avoids OpenSSL ABI issues in the shared library)

Three issues had to be solved beyond a basic build:

1. **GCC 15 C23 compatibility** — paho-mqtt's `typedef unsigned int bool` breaks under GCC 15's default `-std=c23`. Fixed with a preprocessor guard.
2. **Missing C++ runtime** — linking with `gcc` instead of `g++` left `std::string` symbols unresolved. Fixed by using `g++ -lstdc++`.
3. **Version mismatch** — Bambu Studio compares the first 8 characters of the plugin's reported version against its own. bambu-farm hardcodes an old version. Fixed by patching `BAMBU_NETWORK_AGENT_VERSION` to match the installed app version before building.

---

## Credits

- [bambu-farm](https://github.com/ellenhp/bambu-farm) by [@ellenhp](https://github.com/ellenhp) — the open-source plugin reimplementation that makes this possible
- [Bambu Studio](https://github.com/bambulab/BambuStudio) by Bambu Lab

## License

The install script and documentation in this repo are MIT licensed. bambu-farm itself is AGPLv3.
