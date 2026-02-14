# RPM Package for Ferrite

This directory contains the RPM packaging files for building `.rpm` packages for Red Hat, CentOS, Fedora, Rocky Linux, and other RPM-based distributions.

## Packages

- **ferrite** - Main server package
- **ferrite-cli** - Command-line interface package
- **ferrite-tui** - Terminal UI dashboard package

## Building

### Prerequisites

```bash
# Fedora/RHEL 9+/Rocky 9+
sudo dnf install -y \
    rpm-build \
    rpmdevtools \
    rust \
    cargo \
    openssl-devel \
    systemd-rpm-macros

# RHEL 8/Rocky 8/CentOS Stream 8
sudo dnf install -y \
    rpm-build \
    rpmdevtools \
    openssl-devel \
    systemd-rpm-macros

# Install Rust via rustup (if not available in repos)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

### Setup Build Environment

```bash
# Create RPM build directory structure
rpmdev-setuptree

# This creates ~/rpmbuild with:
# - BUILD/
# - BUILDROOT/
# - RPMS/
# - SOURCES/
# - SPECS/
# - SRPMS/
```

### Build the Package

```bash
# From the repository root
cd "$(git rev-parse --show-toplevel)"

# Create source tarball
VERSION=0.1.0
tar czf ~/rpmbuild/SOURCES/ferrite-${VERSION}.tar.gz \
    --transform "s,^,ferrite-${VERSION}/," \
    --exclude='.git' \
    --exclude='target' \
    .

# Copy spec file
cp packaging/rpm/ferrite.spec ~/rpmbuild/SPECS/

# Build the RPM
rpmbuild -ba ~/rpmbuild/SPECS/ferrite.spec

# Packages will be in:
ls ~/rpmbuild/RPMS/x86_64/ferrite*.rpm
```

### Quick Build Script

```bash
#!/bin/bash
set -e

# Configuration
VERSION=0.1.0
REPO_ROOT=$(git rev-parse --show-toplevel)

# Setup
rpmdev-setuptree

# Create source tarball
cd "$REPO_ROOT"
tar czf ~/rpmbuild/SOURCES/ferrite-${VERSION}.tar.gz \
    --transform "s,^,ferrite-${VERSION}/," \
    --exclude='.git' \
    --exclude='target' \
    .

# Copy files
cp packaging/rpm/ferrite.spec ~/rpmbuild/SPECS/

# Build
rpmbuild -ba ~/rpmbuild/SPECS/ferrite.spec

echo "Build complete!"
ls -la ~/rpmbuild/RPMS/x86_64/ferrite*.rpm
```

## Installation

```bash
# Install the main package
sudo rpm -ivh ferrite-0.1.0-1.el9.x86_64.rpm

# Or use dnf/yum
sudo dnf install ./ferrite-0.1.0-1.el9.x86_64.rpm

# Install all packages
sudo dnf install ./ferrite*.rpm
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

# Remove package
sudo dnf remove ferrite

# Remove all data (optional)
sudo rm -rf /var/lib/ferrite /var/log/ferrite /etc/ferrite
```

## Creating a YUM/DNF Repository

To host packages in a YUM repository:

```bash
# Install createrepo
sudo dnf install createrepo_c

# Create repository structure
mkdir -p repo/Packages
cp ~/rpmbuild/RPMS/x86_64/ferrite*.rpm repo/Packages/

# Generate repository metadata
createrepo repo/
```

Create a repo file for users:

```bash
# /etc/yum.repos.d/ferrite.repo
cat > ferrite.repo << EOF
[ferrite]
name=Ferrite Repository
baseurl=https://packages.ferrite.dev/rpm/\$releasever/\$basearch/
enabled=1
gpgcheck=0
EOF
```

Users can then install:
```bash
sudo cp ferrite.repo /etc/yum.repos.d/
sudo dnf install ferrite
```

## SELinux

If SELinux is enforcing, you may need to configure it:

```bash
# Allow Ferrite to bind to its port
sudo semanage port -a -t redis_port_t -p tcp 6379

# Or create a custom policy
# See SELinux documentation for details
```

## Firewall

```bash
# Allow Ferrite port
sudo firewall-cmd --permanent --add-port=6379/tcp
sudo firewall-cmd --reload

# Or create a service
sudo firewall-cmd --permanent --add-service=ferrite
```

## GitHub Actions Integration

See `.github/workflows/release.yml` for automated package building.

## Troubleshooting

### Build Fails

1. Ensure Rust is installed: `rustc --version`
2. Check cargo is available: `cargo --version`
3. Install missing build dependencies:
   ```bash
   sudo dnf builddep ferrite.spec
   ```

### Package Installation Fails

1. Check for missing dependencies:
   ```bash
   sudo dnf install --enablerepo=* ./ferrite*.rpm
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

2. Check SELinux:
   ```bash
   sudo ausearch -m AVC -ts recent
   ```

3. Check permissions:
   ```bash
   ls -laZ /var/lib/ferrite
   ls -laZ /etc/ferrite
   ```

4. Check port availability:
   ```bash
   sudo ss -tlnp | grep 6379
   ```

### SELinux Issues

If Ferrite fails to start due to SELinux:

```bash
# Check for denials
sudo ausearch -m AVC -ts recent | grep ferrite

# Temporarily set to permissive to test
sudo setenforce 0
sudo systemctl start ferrite

# Generate policy module
sudo ausearch -m AVC -ts recent | audit2allow -M ferrite-local
sudo semodule -i ferrite-local.pp

# Re-enable enforcing
sudo setenforce 1
```
