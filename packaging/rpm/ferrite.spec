# Ferrite RPM Spec File

Name:           ferrite
Version:        0.3.0
Release:        1%{?dist}
Summary:        High-performance, tiered-storage key-value store

License:        Apache-2.0
URL:            https://ferrite.rs
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  rust >= 1.80
BuildRequires:  cargo
BuildRequires:  openssl-devel
BuildRequires:  systemd-rpm-macros

Requires:       openssl-libs
Requires(pre):  shadow-utils

%description
Ferrite is a Redis-compatible key-value store with tiered storage
support. It provides the speed of memory, the capacity of disk,
and the economics of cloud.

Features:
- Drop-in Redis replacement with 99% command compatibility
- Tiered storage (memory, SSD, cloud)
- Vector search and embeddings
- Time-series data support
- Graph database capabilities
- CRDT support for distributed systems
- Built-in RAG and semantic caching

%package cli
Summary:        Command-line interface for Ferrite
Requires:       %{name} = %{version}-%{release}

%description cli
The Ferrite command-line interface (ferrite-cli) provides a
Redis-compatible REPL for interacting with Ferrite servers.

%package tui
Summary:        Terminal UI dashboard for Ferrite
Requires:       %{name} = %{version}-%{release}

%description tui
The Ferrite Terminal User Interface (ferrite-tui) provides a
real-time dashboard for monitoring Ferrite servers.

%prep
%autosetup

%build
cargo build --release --locked
# Build CLI if present
if [ -d "ferrite-cli" ]; then
    cargo build --release --locked --manifest-path ferrite-cli/Cargo.toml
fi
# Build TUI if present
if [ -d "ferrite-tui" ]; then
    cargo build --release --locked --manifest-path ferrite-tui/Cargo.toml
fi

%install
# Install main binary
install -D -m 755 target/release/ferrite %{buildroot}%{_bindir}/ferrite

# Install CLI binary if built
if [ -f "target/release/ferrite-cli" ]; then
    install -D -m 755 target/release/ferrite-cli %{buildroot}%{_bindir}/ferrite-cli
fi

# Install TUI binary if built
if [ -f "target/release/ferrite-tui" ]; then
    install -D -m 755 target/release/ferrite-tui %{buildroot}%{_bindir}/ferrite-tui
fi

# Install configuration
install -D -m 640 packaging/rpm/ferrite.conf %{buildroot}%{_sysconfdir}/ferrite/ferrite.toml

# Install systemd service
install -D -m 644 packaging/rpm/ferrite.service %{buildroot}%{_unitdir}/ferrite.service

# Create directories
install -d -m 750 %{buildroot}%{_sharedstatedir}/ferrite
install -d -m 750 %{buildroot}%{_localstatedir}/log/ferrite

%pre
# Create ferrite user and group
getent group ferrite >/dev/null || groupadd -r ferrite
getent passwd ferrite >/dev/null || \
    useradd -r -g ferrite -d %{_sharedstatedir}/ferrite -s /sbin/nologin \
    -c "Ferrite Server" ferrite
exit 0

%post
%systemd_post ferrite.service

%preun
%systemd_preun ferrite.service

%postun
%systemd_postun_with_restart ferrite.service

# Remove user on package removal (not upgrade)
if [ $1 -eq 0 ]; then
    userdel ferrite 2>/dev/null || true
    groupdel ferrite 2>/dev/null || true
fi

%files
%license LICENSE
%doc README.md CHANGELOG.md
%{_bindir}/ferrite
%{_unitdir}/ferrite.service
%dir %attr(750, root, ferrite) %{_sysconfdir}/ferrite
%config(noreplace) %attr(640, root, ferrite) %{_sysconfdir}/ferrite/ferrite.toml
%dir %attr(750, ferrite, ferrite) %{_sharedstatedir}/ferrite
%dir %attr(750, ferrite, ferrite) %{_localstatedir}/log/ferrite

%files cli
%{_bindir}/ferrite-cli

%files tui
%{_bindir}/ferrite-tui

%changelog
* Fri Mar 07 2026 Ferrite Maintainers <maintainers@ferrite.dev> - 0.3.0-1
- Update to v0.3.0
- Cluster mode improvements
- Vector search and full-text search enhancements
- CDC/event streaming

* Sat Jan 01 2025 Ferrite Maintainers <maintainers@ferrite.dev> - 0.1.0-1
- Initial release
- Redis-compatible key-value store with tiered storage
- Support for strings, lists, sets, sorted sets, hashes
- Vector search and embeddings support
- Time-series data capabilities
- Graph database features
- CRDT support for distributed systems
- AOF and checkpoint persistence
- Cluster and replication support
- TLS/mTLS encryption
- ACL authentication
