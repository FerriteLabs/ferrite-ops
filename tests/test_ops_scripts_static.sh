#!/usr/bin/env bash
# Regression tests for ShellCheck findings F-11 fixed in scripts/backup.sh,
# scripts/restore.sh, and scripts/cost-estimate.sh:
#   - SC3040: backup.sh/restore.sh declared `#!/usr/bin/env sh` but used the
#     bash-only `set -o pipefail`, while every other script in scripts/ uses
#     `#!/usr/bin/env bash`. Fixed by using bash consistently.
#   - SC2144: restore.sh used `[ -f "$STAGE_DIR"/glob/backup-metadata.json ]`
#     to locate the extracted backup's content directory. `-f` does not work
#     with a glob that expands to more than one match (passed as multiple
#     arguments to `[`, which errors out silently under `2>/dev/null`) --
#     fixed with an explicit `for` loop.
#   - SC2034: cost-estimate.sh declared `REGION=""` but never wired it into
#     argument parsing, despite the script's own usage example documenting
#     `--region us-east1`. Fixed by wiring up the flag end-to-end.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

BACKUP_SH="${REPO_ROOT}/scripts/backup.sh"
RESTORE_SH="${REPO_ROOT}/scripts/restore.sh"
COST_ESTIMATE_SH="${REPO_ROOT}/scripts/cost-estimate.sh"

for f in "$BACKUP_SH" "$RESTORE_SH" "$COST_ESTIMATE_SH"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

# --- SC3040: shebang consistency ---------------------------------------------
assert_eq "#!/usr/bin/env bash" "$(head -1 "$BACKUP_SH")" \
  "backup.sh uses #!/usr/bin/env bash (matches every other scripts/*.sh, required for pipefail)"
assert_eq "#!/usr/bin/env bash" "$(head -1 "$RESTORE_SH")" \
  "restore.sh uses #!/usr/bin/env bash (matches every other scripts/*.sh, required for pipefail)"
assert_true "$(bash -n "$BACKUP_SH"; echo $?)" "backup.sh is syntactically valid bash"
assert_true "$(bash -n "$RESTORE_SH"; echo $?)" "restore.sh is syntactically valid bash"

# --- SC2144: restore.sh's content-dir discovery must not use `-f` on a glob -
RESTORE_CONTENT="$(cat "$RESTORE_SH")"
assert_not_contains "$RESTORE_CONTENT" '[ -f "$STAGE_DIR"/ferrite-backup-*/backup-metadata.json ]' \
  "restore.sh no longer tests -f directly against an unexpanded multi-match glob"
assert_contains "$RESTORE_CONTENT" 'for candidate in "$STAGE_DIR"/ferrite-backup-*/backup-metadata.json' \
  "restore.sh discovers its content dir via an explicit for loop over the glob"

# Functional replay of the discovery loop (extracted verbatim from
# restore.sh so this test tracks the real implementation, not a duplicate
# that could silently drift) against 0/1/2-match fixtures.
DISCOVERY_SNIPPET="$(awk '/^CONTENT_DIR="\$STAGE_DIR"$/,/^done$/' "$RESTORE_SH")"
HAVE_DISCOVERY_SNIPPET=1
[[ -n "$DISCOVERY_SNIPPET" ]] && HAVE_DISCOVERY_SNIPPET=0
assert_true "$HAVE_DISCOVERY_SNIPPET" \
  "extracted restore.sh's CONTENT_DIR discovery loop for functional replay"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

run_discovery() {
  local stage_dir="$1"
  # shellcheck disable=SC2034  # STAGE_DIR is consumed indirectly by the eval'd DISCOVERY_SNIPPET below.
  ( STAGE_DIR="$stage_dir"; eval "$DISCOVERY_SNIPPET"; echo "$CONTENT_DIR" )
}

# No match: falls back to STAGE_DIR itself.
NO_MATCH_DIR="${WORK_DIR}/no-match"
mkdir -p "$NO_MATCH_DIR"
assert_eq "$NO_MATCH_DIR" "$(run_discovery "$NO_MATCH_DIR")" \
  "no ferrite-backup-*/backup-metadata.json present -> CONTENT_DIR falls back to STAGE_DIR"

# Single match: resolves to the nested directory.
SINGLE_DIR="${WORK_DIR}/single-match"
mkdir -p "${SINGLE_DIR}/ferrite-backup-20240101_000000"
touch "${SINGLE_DIR}/ferrite-backup-20240101_000000/backup-metadata.json"
assert_eq "${SINGLE_DIR}/ferrite-backup-20240101_000000" "$(run_discovery "$SINGLE_DIR")" \
  "a single ferrite-backup-*/backup-metadata.json resolves CONTENT_DIR to that nested directory"

# Multiple matches: previously errored out (silently swallowed by
# 2>/dev/null) and fell back to STAGE_DIR; now deterministically picks the
# first glob-sorted match instead of silently mis-resolving.
MULTI_DIR="${WORK_DIR}/multi-match"
mkdir -p "${MULTI_DIR}/ferrite-backup-1" "${MULTI_DIR}/ferrite-backup-2"
touch "${MULTI_DIR}/ferrite-backup-1/backup-metadata.json" "${MULTI_DIR}/ferrite-backup-2/backup-metadata.json"
assert_eq "${MULTI_DIR}/ferrite-backup-1" "$(run_discovery "$MULTI_DIR")" \
  "multiple ferrite-backup-*/backup-metadata.json matches resolve deterministically instead of erroring/falling back to STAGE_DIR"

# --- SC2034: cost-estimate.sh's --region must be wired end-to-end ----------
COST_ESTIMATE_CONTENT="$(cat "$COST_ESTIMATE_SH")"
assert_contains "$COST_ESTIMATE_CONTENT" '--region) REGION="$2"; shift 2 ;;' \
  "cost-estimate.sh parses --region into the REGION variable"
assert_contains "$COST_ESTIMATE_CONTENT" '"  Region:' \
  "cost-estimate.sh prints REGION in its report output"

if command -v bc >/dev/null 2>&1; then
  WITHOUT_REGION_OUT="$(bash "$COST_ESTIMATE_SH" --dataset-size 100 --hot-ratio 0.2 --cloud aws 2>&1)"
  assert_not_contains "$WITHOUT_REGION_OUT" "Region:" \
    "cost-estimate.sh omits the Region line when --region is not provided"

  WITH_REGION_OUT="$(bash "$COST_ESTIMATE_SH" --dataset-size 100 --hot-ratio 0.2 --cloud aws --region us-east1 2>&1)"
  assert_contains "$WITH_REGION_OUT" "Region:            us-east1" \
    "cost-estimate.sh prints the provided --region value in its report"
else
  echo "  skip: 'bc' not available; skipping functional cost-estimate.sh --region checks"
fi

harness_summary
