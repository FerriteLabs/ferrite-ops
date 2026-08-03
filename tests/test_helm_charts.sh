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

harness_summary
