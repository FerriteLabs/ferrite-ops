#!/usr/bin/env bash
# Policy-neutral Helm chart checks. Runs `helm lint` and a `helm template`
# dry-run render against every chart under charts/, using default values
# plus each chart's alternate values files where present. No Kubernetes
# cluster or Tiller/Helm server component is required (Helm 3 is
# client-only). If `helm` isn't installed, this test clearly skips instead
# of failing so the rest of tests/run.sh stays useful without it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if ! command -v helm >/dev/null 2>&1; then
  echo "  skip: helm is not installed in this environment; skipping Helm checks."
  echo "  (CI installs helm via azure/setup-helm before running this suite.)"
  exit 0
fi

shopt -s nullglob
CHART_DIRS=("${REPO_ROOT}"/charts/*/)
shopt -u nullglob

if [[ ${#CHART_DIRS[@]} -eq 0 ]]; then
  echo "  FAIL: no charts found under ${REPO_ROOT}/charts" >&2
  exit 1
fi

for chart_dir in "${CHART_DIRS[@]}"; do
  chart_name="$(basename "$chart_dir")"

  if helm lint "$chart_dir" >/tmp/helm_lint_output.$$ 2>&1; then
    harness_ok "helm lint passes for chart '${chart_name}'"
  else
    harness_fail "helm lint failed for chart '${chart_name}': $(cat /tmp/helm_lint_output.$$)"
  fi
  rm -f /tmp/helm_lint_output.$$

  if helm template "$chart_name" "$chart_dir" >/tmp/helm_template_output.$$ 2>&1; then
    harness_ok "helm template renders default values for chart '${chart_name}'"
  else
    harness_fail "helm template failed for chart '${chart_name}': $(cat /tmp/helm_template_output.$$)"
  fi
  rm -f /tmp/helm_template_output.$$

  shopt -s nullglob
  ALT_VALUES=("${chart_dir}"values*.yaml)
  shopt -u nullglob
  for values_file in "${ALT_VALUES[@]}"; do
    [[ "$(basename "$values_file")" == "values.yaml" ]] && continue
    values_name="$(basename "$values_file")"
    if helm template "$chart_name" "$chart_dir" -f "$values_file" >/tmp/helm_template_alt.$$ 2>&1; then
      harness_ok "helm template renders '${values_name}' for chart '${chart_name}'"
    else
      harness_fail "helm template with '${values_name}' failed for chart '${chart_name}': $(cat /tmp/helm_template_alt.$$)"
    fi
    rm -f /tmp/helm_template_alt.$$
  done
done

# --- Chart-specific render assertions ---------------------------------------
# The injected Ferrite sidecar image must follow the chart's appVersion, which
# release automation keeps in sync with the released Ferrite version, instead
# of a floating tag that silently drifts from the release.
SIDECAR_CHART="${REPO_ROOT}/charts/ferrite-sidecar"
SIDECAR_VALUES="${SIDECAR_CHART}/values.yaml"
SIDECAR_APP_VERSION="$(grep -E '^appVersion:' "${SIDECAR_CHART}/Chart.yaml" \
  | head -1 | sed -E 's/^appVersion:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')"
SIDECAR_TAG_DEFAULT="$(awk '/^sidecar:/{in_sidecar=1} in_sidecar && /^[[:space:]]+tag:/{print $2; exit}' \
  "$SIDECAR_VALUES")"

assert_eq '""' "${SIDECAR_TAG_DEFAULT:-unset}" \
  "values.yaml leaves sidecar.image.tag empty so the chart appVersion is used"

if DEFAULT_RENDER="$(helm template ferrite-sidecar "$SIDECAR_CHART" 2>&1)"; then
  assert_contains "$DEFAULT_RENDER" "--sidecar-image=ghcr.io/ferritelabs/ferrite:${SIDECAR_APP_VERSION}" \
    "default render injects the Ferrite sidecar image at the synced chart appVersion (${SIDECAR_APP_VERSION})"
  assert_not_contains "$DEFAULT_RENDER" "ghcr.io/ferritelabs/ferrite:latest" \
    "default render never injects a floating :latest Ferrite image"
else
  harness_fail "helm template failed for the sidecar chart: ${DEFAULT_RENDER}"
fi

if OVERRIDE_RENDER="$(helm template ferrite-sidecar "$SIDECAR_CHART" \
  --set sidecar.image.tag=9.9.9-override 2>&1)"; then
  assert_contains "$OVERRIDE_RENDER" "--sidecar-image=ghcr.io/ferritelabs/ferrite:9.9.9-override" \
    "an explicit sidecar.image.tag override wins over the chart appVersion"
  assert_not_contains "$OVERRIDE_RENDER" "--sidecar-image=ghcr.io/ferritelabs/ferrite:${SIDECAR_APP_VERSION}" \
    "an explicit override fully replaces the appVersion-derived tag"
else
  harness_fail "helm template with a sidecar tag override failed: ${OVERRIDE_RENDER}"
fi

# The chart appVersion is what release automation synchronizes, so an
# appVersion bump must move the injected sidecar image with it.
SYNCED_CHART_DIR="$(mktemp -d)"
cp -R "$SIDECAR_CHART"/. "$SYNCED_CHART_DIR/"
perl -pi -e 's/^appVersion:.*/appVersion: "9.8.7"/' "${SYNCED_CHART_DIR}/Chart.yaml"
if SYNCED_RENDER="$(helm template ferrite-sidecar "$SYNCED_CHART_DIR" 2>&1)"; then
  assert_contains "$SYNCED_RENDER" "--sidecar-image=ghcr.io/ferritelabs/ferrite:9.8.7" \
    "a synced appVersion moves the injected sidecar image without any values change"
else
  harness_fail "helm template of the appVersion-synced sidecar chart failed: ${SYNCED_RENDER}"
fi
rm -rf "$SYNCED_CHART_DIR"

harness_summary
