#!/usr/bin/env bash
# Validates that `docker compose up` against the default docker-compose.yml
# never overrides the image's own generated, build-time-validated
# /etc/ferrite/ferrite.toml, and that a custom config remains available as an
# explicit, documented opt-in override rather than a silent default.
#
# Two layers of coverage:
#   1. Static/textual checks against the compose YAML (no Docker needed).
#   2. `docker compose config` merge checks proving the *resolved* default
#      service has no ferrite.toml bind mount, and that layering the
#      opt-in override on top adds exactly one, pointed at the documented
#      default path — skipped cleanly if docker compose is unavailable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

DEFAULT_COMPOSE="${REPO_ROOT}/docker-compose.yml"
CUSTOM_CONFIG_OVERRIDE="${REPO_ROOT}/docker/docker-compose.custom-config.yml"
QUICKSTART_COMPOSE="${REPO_ROOT}/docker-compose.quickstart.yml"
MOONSHOT_COMPOSE="${REPO_ROOT}/docker-compose.moonshot.yml"

for f in "$DEFAULT_COMPOSE" "$CUSTOM_CONFIG_OVERRIDE" "$QUICKSTART_COMPOSE" "$MOONSHOT_COMPOSE"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

# --- Static checks ----------------------------------------------------------
DEFAULT_CONTENT="$(cat "$DEFAULT_COMPOSE")"
OVERRIDE_CONTENT="$(cat "$CUSTOM_CONFIG_OVERRIDE")"
QUICKSTART_CONTENT="$(cat "$QUICKSTART_COMPOSE")"
MOONSHOT_CONTENT="$(cat "$MOONSHOT_COMPOSE")"

assert_not_contains "$DEFAULT_CONTENT" "\${FERRITE_CONFIG:-./ferrite.example.toml}:/etc/ferrite/ferrite.toml" \
  "default docker-compose.yml does not mount the public example over the image's own config"
assert_not_contains "$DEFAULT_CONTENT" "/etc/ferrite/ferrite.toml:ro" \
  "default docker-compose.yml's ferrite service has no ferrite.toml bind mount of any kind"
assert_not_contains "$QUICKSTART_CONTENT" "ferrite.example.toml" \
  "quickstart Compose does not replace the image's generated, verified default config"
assert_not_contains "$MOONSHOT_CONTENT" "ferrite.example.toml" \
  "Moonshot Compose does not replace the image's generated, verified default config"
assert_contains "$OVERRIDE_CONTENT" "ferrite.example.toml" \
  "the opt-in override documents ferrite.example.toml as its default custom-config source"
assert_contains "$OVERRIDE_CONTENT" '${FERRITE_CONFIG:-' \
  "the opt-in override still lets FERRITE_CONFIG point at a different file"
assert_contains "$DEFAULT_CONTENT" "docker/docker-compose.custom-config.yml" \
  "the default compose file documents how to opt in to a custom config"

# --- docker compose config merge checks -------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "  skip: docker is not installed in this environment; skipping docker compose config checks."
  harness_summary
  exit $?
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "  skip: docker compose is not available in this environment."
  harness_summary
  exit $?
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3's PyYAML module is not available; skipping docker compose config checks."
  harness_summary
  exit $?
fi

# The default Compose file's grafana service requires this env var just to
# interpolate/resolve `docker compose config`; it has no bearing on the
# config-mount behavior this test actually verifies.
export GRAFANA_ADMIN_PASSWORD="test-only-placeholder"

DEFAULT_RESOLVED="$(mktemp)"
OVERRIDE_RESOLVED="$(mktemp)"
trap 'rm -f "$DEFAULT_RESOLVED" "$OVERRIDE_RESOLVED"' EXIT

if (cd "$REPO_ROOT" && docker compose -f docker-compose.yml config) >"$DEFAULT_RESOLVED" 2>&1; then
  harness_ok "docker compose config resolves the default docker-compose.yml"
else
  harness_fail "docker compose config failed on the default docker-compose.yml: $(tail -20 "$DEFAULT_RESOLVED")"
  harness_summary
  exit $?
fi

if (cd "$REPO_ROOT" && docker compose -f docker-compose.yml \
  -f docker/docker-compose.custom-config.yml config) >"$OVERRIDE_RESOLVED" 2>&1; then
  harness_ok "docker compose config resolves docker-compose.yml with the custom-config override layered on"
else
  harness_fail "docker compose config failed with the custom-config override: $(tail -20 "$OVERRIDE_RESOLVED")"
  harness_summary
  exit $?
fi

DEFAULT_VOLUME_COUNT="$(python3 -c "
import sys
import yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
print(len(doc['services']['ferrite'].get('volumes', [])))
" "$DEFAULT_RESOLVED")"
assert_eq "1" "$DEFAULT_VOLUME_COUNT" \
  "the resolved default ferrite service has exactly one volume (its data volume, no config mount)"

DEFAULT_HAS_TOML_MOUNT="$(python3 -c "
import sys
import yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
volumes = doc['services']['ferrite'].get('volumes', [])
print('yes' if any(v.get('target') == '/etc/ferrite/ferrite.toml' for v in volumes) else 'no')
" "$DEFAULT_RESOLVED")"
assert_eq "no" "$DEFAULT_HAS_TOML_MOUNT" \
  "the resolved default ferrite service does not bind-mount /etc/ferrite/ferrite.toml"

OVERRIDE_TOML_SOURCE="$(python3 -c "
import sys
import yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
volumes = doc['services']['ferrite'].get('volumes', [])
matches = [v['source'] for v in volumes if v.get('target') == '/etc/ferrite/ferrite.toml']
print(matches[0] if matches else '')
" "$OVERRIDE_RESOLVED")"
assert_contains "$OVERRIDE_TOML_SOURCE" "ferrite.example.toml" \
  "layering the opt-in override resolves the config mount to ferrite.example.toml by default"

# --- Real runtime check: `docker compose up` with zero overrides -----------
# Builds and starts the actual default `ferrite` service (no -f override, no
# FERRITE_CONFIG) and proves the *running* container's /etc/ferrite/ferrite.toml
# is the image's own generated, build-time-validated config, matching what
# `docker compose config` above already proved is mounted (nothing). Docker's
# build cache keeps repeat runs fast; skips cleanly if the daemon is
# unreachable, mirroring the other Docker-dependent tests in this suite.
if ! docker info >/dev/null 2>&1; then
  echo "  skip: no reachable Docker daemon; skipping the real docker compose up runtime check."
  harness_summary
  exit $?
fi

PROJECT="ferrite-ops-test-default-compose-$$"
COMPOSE_LOG="$(mktemp)"
compose_cleanup() {
  (cd "$REPO_ROOT" && docker compose -p "$PROJECT" -f docker-compose.yml down --volumes --remove-orphans)     >>"$COMPOSE_LOG" 2>&1 || true
  rm -f "$COMPOSE_LOG"
}
trap 'compose_cleanup; rm -f "$DEFAULT_RESOLVED" "$OVERRIDE_RESOLVED"' EXIT

if (cd "$REPO_ROOT" && docker compose -p "$PROJECT" -f docker-compose.yml up -d --build ferrite)   >"$COMPOSE_LOG" 2>&1; then
  harness_ok "docker compose up builds and starts the default ferrite service with zero overrides"
else
  harness_fail "docker compose up failed for the default ferrite service: $(tail -40 "$COMPOSE_LOG")"
  harness_summary
  exit $?
fi

RUNNING_CONFIG="$(mktemp)"
if (cd "$REPO_ROOT" && docker compose -p "$PROJECT" -f docker-compose.yml exec -T ferrite   cat /etc/ferrite/ferrite.toml) >"$RUNNING_CONFIG" 2>>"$COMPOSE_LOG"; then
  harness_ok "the running default-compose container's config is readable"
else
  harness_fail "could not read /etc/ferrite/ferrite.toml from the running default-compose container: $(tail -40 "$COMPOSE_LOG")"
fi
assert_contains "$(cat "$RUNNING_CONFIG")" "Generated by \`ferrite init\`"   "the running default-compose container uses the image's own generated config, not a mounted example"
assert_not_contains "$(cat "$RUNNING_CONFIG")" 'max_memory = "1GB"'   "the running default-compose container's config is not the public example (F-17 regression guard)"
rm -f "$RUNNING_CONFIG"

harness_summary
