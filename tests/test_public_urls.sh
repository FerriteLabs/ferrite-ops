#!/usr/bin/env bash
# Prevents unreachable Ferrite-owned domain URLs and public contact instructions from returning while allowing Kubernetes annotation keys and required Debian package signatures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

DEAD_URL_RE='https?://[^[:space:]"'"'"'<>)]*ferrite(labs)?\.(dev|rs)'
DEAD_URLS="$(git -C "$REPO_ROOT" grep -nE "$DEAD_URL_RE" -- . ':(exclude)tests/test_public_urls.sh' || true)"
assert_eq "" "$DEAD_URLS" \
  "tracked files contain no HTTP URLs on unowned or parked Ferrite domains"

DOMAIN_CONTACT_RE='@ferrite(labs)?\.(dev|rs)'
DOMAIN_CONTACTS="$(git -C "$REPO_ROOT" grep -nE "$DOMAIN_CONTACT_RE" -- . ':(exclude)tests/test_public_urls.sh' || true)"
UNALLOWED_DOMAIN_CONTACTS="$(printf '%s\n' "$DOMAIN_CONTACTS" | grep -vE '^packaging/(deb/debian/(control|changelog)|rpm/ferrite\.spec):' || true)"
assert_eq "" "$UNALLOWED_DOMAIN_CONTACTS" \
  "unverified domain email addresses appear only in required or historical package metadata fields"

SUPPORT_CONTENT="$(cat "${REPO_ROOT}/SUPPORT.md")"
assert_not_contains "$SUPPORT_CONTENT" "support@ferrite.rs" \
  "SUPPORT.md does not advertise the unverified commercial support mailbox"
assert_not_contains "$SUPPORT_CONTENT" "## Commercial Support" \
  "SUPPORT.md does not claim a commercial support channel"
assert_contains "$SUPPORT_CONTENT" "https://github.com/ferritelabs/ferrite-docs" \
  "SUPPORT.md sends users to the reachable documentation repository"

SECURITY_CONTENT="$(cat "${REPO_ROOT}/SECURITY.md")"
assert_not_contains "$SECURITY_CONTENT" "security@ferritelabs.dev" \
  "SECURITY.md does not advertise the unverified security mailbox"
assert_contains "$SECURITY_CONTENT" \
  "https://github.com/ferritelabs/ferrite-ops/security/advisories/new" \
  "SECURITY.md publishes GitHub private vulnerability reporting"
assert_contains "$SECURITY_CONTENT" "only published security intake" \
  "SECURITY.md identifies one private security intake"

PRIMARY_CHART="$(cat "${REPO_ROOT}/charts/ferrite/Chart.yaml")"
SIDECAR_CHART="$(cat "${REPO_ROOT}/charts/ferrite-sidecar/Chart.yaml")"
for chart_content in "$PRIMARY_CHART" "$SIDECAR_CHART"; do
  assert_contains "$chart_content" "home: https://github.com/ferritelabs/ferrite" \
    "chart product home uses the reachable Ferrite repository"
  assert_not_contains "$chart_content" "email:" \
    "optional chart maintainer email is omitted until a verified mailbox exists"
done
assert_contains "$PRIMARY_CHART" \
  "https://github.com/ferritelabs/ferrite-ops/blob/main/charts/ferrite/README.md" \
  "primary chart metadata links to its precise GitHub documentation"
assert_contains "$SIDECAR_CHART" \
  "https://github.com/ferritelabs/ferrite-ops/blob/main/charts/ferrite-sidecar/README.md" \
  "sidecar chart metadata links to its precise GitHub documentation"
assert_contains "$(cat "${REPO_ROOT}/charts/ferrite/templates/NOTES.txt")" \
  "https://github.com/ferritelabs/ferrite-docs" \
  "rendered chart notes link to the reachable documentation repository"

assert_contains "$(cat "${REPO_ROOT}/packaging/deb/debian/control")" \
  "Maintainer: Ferrite Maintainers <maintainers@ferrite.dev>" \
  "required Debian maintainer field remains unchanged pending mailbox verification"
assert_contains "$(cat "${REPO_ROOT}/packaging/deb/debian/control")" \
  "Homepage: https://github.com/ferritelabs/ferrite" \
  "Debian Homepage uses the reachable Ferrite repository"
assert_contains "$(cat "${REPO_ROOT}/packaging/rpm/ferrite.spec")" \
  "URL:            https://github.com/ferritelabs/ferrite" \
  "RPM package URL uses the reachable Ferrite repository"
for service_file in \
  packaging/deb/debian/ferrite.service \
  packaging/rpm/ferrite.service; do
  assert_contains "$(cat "${REPO_ROOT}/${service_file}")" \
    "Documentation=https://github.com/ferritelabs/ferrite-docs" \
    "${service_file} uses the reachable documentation repository"
done
for config_file in \
  packaging/deb/debian/ferrite.conf \
  packaging/rpm/ferrite.conf; do
  assert_contains "$(cat "${REPO_ROOT}/${config_file}")" \
    "https://github.com/ferritelabs/ferrite-docs" \
    "${config_file} uses the reachable documentation repository"
done
assert_contains "$(cat "${REPO_ROOT}/docker-compose.quickstart.yml")" \
  "Documentation: https://github.com/ferritelabs/ferrite-docs" \
  "quickstart output uses the reachable documentation repository"

SIDECAR_IDENTIFIERS="$(cat "${REPO_ROOT}/charts/ferrite-sidecar/values.yaml" "${REPO_ROOT}/charts/ferrite-sidecar/templates/webhook.yaml")"
assert_contains "$SIDECAR_IDENTIFIERS" "ferrite.dev/inject" \
  "Kubernetes annotation and label keys remain valid API identifiers rather than being treated as public URLs"

GRAFANA_DOC_LINKS="$(grep -RIl \
  '"title": "Ferrite Documentation"' \
  "${REPO_ROOT}/grafana" \
  "${REPO_ROOT}/monitoring/grafana" \
  "${REPO_ROOT}/docker/grafana")"
if [[ -n "$GRAFANA_DOC_LINKS" ]]; then
  harness_ok "found Grafana dashboards with documentation links"
else
  harness_fail "found Grafana dashboards with documentation links"
fi
while IFS= read -r dashboard; do
  [[ -z "$dashboard" ]] && continue
  assert_contains "$(cat "$dashboard")" \
    '"url": "https://github.com/ferritelabs/ferrite-docs"' \
    "${dashboard#${REPO_ROOT}/} uses the reachable documentation repository"
done <<<"$GRAFANA_DOC_LINKS"

README_CONTENT="$(cat "${REPO_ROOT}/README.md")"
CHANGELOG_CONTENT="$(cat "${REPO_ROOT}/CHANGELOG.md")"
assert_contains "$README_CONTENT" "### Public promotion blocker" \
  "release documentation records the public promotion blocker"
assert_contains "$README_CONTENT" "required Debian Maintainer mailbox" \
  "release documentation requires the package mailbox to be verified before public promotion"
assert_contains "$README_CONTENT" "Chart maintainer email fields are omitted" \
  "release documentation records why optional chart email fields are absent"
assert_contains "$CHANGELOG_CONTENT" "Public promotion remains blocked until the hosted documentation endpoint and the required Debian Maintainer mailbox" \
  "changelog records the hosted-documentation and mailbox promotion blocker"

harness_summary
