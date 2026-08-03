#!/usr/bin/env bash
# Writes fake `ferrite` and `ferrite-cli` executables into the directory
# given as $1, for use by tests/test_smoke_test_*.sh. These fakes never talk
# to a real Ferrite server; they only implement enough of the CLI surface
# (`init`, server start with --port/--metrics-port, and a PING responder) for
# smoke_test.sh to exercise its full success/failure/cleanup paths.
set -euo pipefail

DEST_DIR="${1:?usage: make_fake_ferrite.sh <dest-dir>}"
mkdir -p "$DEST_DIR"

cat > "${DEST_DIR}/ferrite" << 'FAKE_FERRITE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "init" ]]; then
  shift
  OUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) OUT="$2"; shift 2 ;;
      --data-dir) mkdir -p "$2"; shift 2 ;;
      --force|--minimal) shift ;;
      *) shift ;;
    esac
  done
  : > "$OUT"
  exit 0
fi

PORT=6379
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

exec python3 -c "
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', ${PORT}))
s.listen(5)
while True:
    conn, _ = s.accept()
    try:
        conn.recv(1024)
        conn.sendall(b'+PONG\r\n')
    finally:
        conn.close()
"
FAKE_FERRITE

cat > "${DEST_DIR}/ferrite-cli" << 'FAKE_FERRITE_CLI'
#!/usr/bin/env bash
set -euo pipefail
PORT=6379
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', ${PORT}))
    s.sendall(b'PING\r\n')
    data = s.recv(100)
    sys.stdout.write(data.decode())
    sys.exit(0 if data.strip() == b'+PONG' else 1)
except OSError:
    sys.exit(1)
"
FAKE_FERRITE_CLI

chmod +x "${DEST_DIR}/ferrite" "${DEST_DIR}/ferrite-cli"
