# Debian/Ubuntu Package for Ferrite

This directory contains the Debian packaging files for building `.deb` packages.

## Packages

- **ferrite** - Main server package
- **ferrite-cli** - Command-line interface package
- **ferrite-tui** - Terminal UI dashboard package

## Building

### Prerequisites

```bash
# Install build dependencies
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    devscripts \
    debhelper \
    cargo \
    rustc \
    libssl-dev \
    pkg-config
```

### Build the Package

From the repository root:

```bash
# Copy debian directory to source root
cp -r packaging/deb/debian .

# Build the package
debuild -us -uc -b

# Or use dpkg-buildpackage
dpkg-buildpackage -us -uc -b

# Packages will be created in the parent directory
ls ../*.deb
```

### Quick Build Script

```bash
#!/bin/bash
set -e

# Ensure we're in the repo root
cd "$(git rev-parse --show-toplevel)"

# Copy debian files
cp -r packaging/deb/debian .

# Build
debuild -us -uc -b

# Clean up
rm -rf debian

echo "Packages built successfully!"
ls -la ../*.deb
```

## Installation

```bash
# Install the main package
sudo dpkg -i ferrite_0.1.0-1_amd64.deb

# Fix any dependency issues
sudo apt-get install -f

# Or install all packages
sudo dpkg -i ferrite*.deb
sudo apt-get install -f
```

## Post-Installation

```bash
# Enable and start the service
sudo systemctl enable ferrite
sudo systemctl start ferrite

# Check status
sudo systemctl status ferrite

# View logs
sudo journalctl -u ferrite -f
```

## Configuration

Configuration file: `/etc/ferrite/ferrite.toml`

Edit configuration:
```bash
sudo nano /etc/ferrite/ferrite.toml
sudo systemctl restart ferrite
```

## Data Locations

- **Data directory**: `/var/lib/ferrite`
- **Log directory**: `/var/log/ferrite`
- **Configuration**: `/etc/ferrite`

## Uninstallation

```bash
# Stop and disable service
sudo systemctl stop ferrite
sudo systemctl disable ferrite

# Remove package (keeps config and data)
sudo apt-get remove ferrite

# Remove package and all data
sudo apt-get purge ferrite
```

## Creating a Repository

To host packages in an APT repository:

```bash
# Install reprepro
sudo apt-get install reprepro

# Create repository structure
mkdir -p repo/conf
cat > repo/conf/distributions << EOF
Codename: stable
Components: main
Architectures: amd64 arm64
EOF

# Add package
reprepro -b repo includedeb stable ferrite_0.1.0-1_amd64.deb
```

Users can then add your repository:

```bash
# Add repository (replace with your URL)
echo "deb [trusted=yes] https://packages.ferrite.dev/apt stable main" | \
    sudo tee /etc/apt/sources.list.d/ferrite.list

# Install
sudo apt-get update
sudo apt-get install ferrite
```

## GitHub Actions Integration

See `.github/workflows/release.yml` for automated package building.

## Troubleshooting

### Build Fails

1. Ensure Rust is installed: `rustc --version`
2. Check cargo is available: `cargo --version`
3. Install missing dependencies: `sudo apt-get build-dep ferrite`

### Package Installation Fails

1. Check for missing dependencies:
   ```bash
   sudo dpkg -i ferrite_*.deb
   sudo apt-get install -f
   ```

2. Check system logs:
   ```bash
   sudo journalctl -xe
   ```

### Service Won't Start

1. Check configuration:
   ```bash
   ferrite --test-config --config /etc/ferrite/ferrite.toml
   ```

2. Check permissions:
   ```bash
   ls -la /var/lib/ferrite
   ls -la /etc/ferrite
   ```

3. Check port availability:
   ```bash
   sudo ss -tlnp | grep 6379
   ```
