#!/usr/bin/env python3
"""Compute stable floating-tag state from immutable exact GHCR tags.

This helper is intentionally registry-independent: it only parses supplied
GitHub Packages API data or verified exact-tag records and writes a
deterministic JSON result. Network access, signature verification, metadata
inspection, and registry mutation remain workflow responsibilities.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from functools import cmp_to_key
from pathlib import Path
from typing import Any


EXACT_STABLE_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


class ReconciliationError(ValueError):
    """Raised when registry data cannot produce a trustworthy plan."""


class SemVer:
    """Adapter around the repository's shared strict SemVer implementation."""

    def __init__(self, ordering_script: Path) -> None:
        self.ordering_script = ordering_script

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [str(self.ordering_script), *args],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as exc:
            raise ReconciliationError(
                f"could not execute shared SemVer comparator "
                f"{self.ordering_script}: {exc}"
            ) from exc

    def validate(self, version: str) -> None:
        result = self._run("validate", version)
        if result.returncode != 0:
            detail = result.stderr.strip() or "strict SemVer validation failed"
            raise ReconciliationError(f"invalid exact version {version!r}: {detail}")

    def is_valid(self, version: str) -> bool:
        result = self._run("validate", version)
        if result.returncode == 0:
            return True
        if result.returncode == 2:
            return False
        detail = result.stderr.strip() or "strict SemVer validation failed"
        raise ReconciliationError(
            f"could not validate exact version {version!r}: {detail}"
        )

    def compare(self, left: str, right: str) -> int:
        result = self._run("semver-cmp", left, right)
        if result.returncode != 0:
            detail = result.stderr.strip() or "strict SemVer comparison failed"
            raise ReconciliationError(
                f"could not compare {left!r} with {right!r}: {detail}"
            )
        outcome = result.stdout.strip()
        if outcome == "lt":
            return -1
        if outcome == "eq":
            return 0
        if outcome == "gt":
            return 1
        raise ReconciliationError(
            f"shared SemVer comparator returned unexpected output: {outcome!r}"
        )


def load_json(path: str) -> Any:
    try:
        if path == "-":
            return json.load(sys.stdin)
        with open(path, encoding="utf-8") as input_file:
            return json.load(input_file)
    except (OSError, json.JSONDecodeError) as exc:
        raise ReconciliationError(f"could not read JSON input {path!r}: {exc}") from exc


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def flatten_pages(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ReconciliationError("GHCR API input must be a JSON array")
    if not value:
        return []

    if all(isinstance(item, dict) for item in value):
        pages: list[Any] = [value]
    elif all(isinstance(item, list) for item in value):
        pages = value
    else:
        raise ReconciliationError(
            "GHCR API input must be one page or an array of paginated pages"
        )

    records: list[dict[str, Any]] = []
    for page_number, page in enumerate(pages, start=1):
        if not isinstance(page, list) or not all(
            isinstance(item, dict) for item in page
        ):
            raise ReconciliationError(
                f"GHCR API page {page_number} is not an array of objects"
            )
        records.extend(page)
    return records


def discover_exact_tags(
    api_value: Any, semver: SemVer
) -> list[dict[str, str]]:
    discovered: dict[str, str] = {}
    for record_number, record in enumerate(flatten_pages(api_value), start=1):
        digest = record.get("name")
        metadata = record.get("metadata")
        container = metadata.get("container") if isinstance(metadata, dict) else None
        tags = container.get("tags") if isinstance(container, dict) else None
        if not isinstance(tags, list):
            raise ReconciliationError(
                f"GHCR API record {record_number} has no container tag array"
            )

        exact_tags = [
            tag
            for tag in tags
            if isinstance(tag, str) and EXACT_STABLE_RE.fullmatch(tag)
        ]
        if not exact_tags:
            continue
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise ReconciliationError(
                f"GHCR API record {record_number} has exact stable tags but "
                f"an invalid digest: {digest!r}"
            )

        for tag in exact_tags:
            # The broad shape filter deliberately catches exact-looking
            # values such as 01.2.3; the shared strict validator is the final
            # authority and rejects them as sources without making unrelated
            # valid exact tags on other package versions unusable.
            if not semver.is_valid(tag):
                continue
            previous = discovered.get(tag)
            if previous is not None and previous != digest:
                raise ReconciliationError(
                    f"exact tag {tag!r} appears on multiple digests: "
                    f"{previous} and {digest}"
                )
            discovered[tag] = digest

    versions = sorted(discovered, key=cmp_to_key(semver.compare))
    return [{"version": version, "digest": discovered[version]} for version in versions]


def load_verified_records(value: Any, semver: SemVer) -> dict[str, str]:
    if not isinstance(value, list):
        raise ReconciliationError("verified exact-tag input must be a JSON array")

    verified: dict[str, str] = {}
    for record_number, record in enumerate(value, start=1):
        if not isinstance(record, dict):
            raise ReconciliationError(
                f"verified exact-tag record {record_number} is not an object"
            )
        version = record.get("version")
        digest = record.get("digest")
        if not isinstance(version, str) or not EXACT_STABLE_RE.fullmatch(version):
            raise ReconciliationError(
                f"verified exact-tag record {record_number} has a non-exact "
                f"stable version: {version!r}"
            )
        semver.validate(version)
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise ReconciliationError(
                f"verified exact-tag record {record_number} has an invalid "
                f"digest: {digest!r}"
            )
        previous = verified.get(version)
        if previous is not None and previous != digest:
            raise ReconciliationError(
                f"verified exact tag {version!r} has conflicting digests: "
                f"{previous} and {digest}"
            )
        verified[version] = digest
    return verified


def newer_version(candidate: str, current: str | None, semver: SemVer) -> bool:
    return current is None or semver.compare(candidate, current) > 0


def compute_plan(value: Any, semver: SemVer) -> list[dict[str, str]]:
    verified = load_verified_records(value, semver)
    desired: dict[str, str] = {}

    for version in verified:
        major, minor, _patch = version.split(".")
        for tag in ("latest", major, f"{major}.{minor}"):
            if newer_version(version, desired.get(tag), semver):
                desired[tag] = version

    def compare_entries(left: tuple[str, str], right: tuple[str, str]) -> int:
        left_tag, left_version = left
        right_tag, right_version = right
        if left_tag == "latest":
            return -1 if right_tag != "latest" else 0
        if right_tag == "latest":
            return 1
        version_result = semver.compare(left_version, right_version)
        if version_result != 0:
            return version_result
        return (left_tag > right_tag) - (left_tag < right_tag)

    entries = sorted(desired.items(), key=cmp_to_key(compare_entries))
    return [
        {"tag": tag, "version": version, "digest": verified[version]}
        for tag, version in entries
    ]


def certificate_identity(
    repository: str, version: str, default_branch: str, semver: SemVer
) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReconciliationError(f"invalid repository identity: {repository!r}")
    if not EXACT_STABLE_RE.fullmatch(version):
        raise ReconciliationError(
            f"certificate identity requires an exact stable version: {version!r}"
        )
    semver.validate(version)
    if not default_branch or any(char in default_branch for char in "\r\n"):
        raise ReconciliationError(
            f"invalid default branch for certificate identity: {default_branch!r}"
        )

    refs = [f"tags/v{re.escape(version)}", "heads/main"]
    if default_branch != "main":
        refs.append(f"heads/{re.escape(default_branch)}")
    return (
        rf"^https://github\.com/{re.escape(repository)}"
        rf"/\.github/workflows/release\.yml@refs/({'|'.join(refs)})$"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ordering-script",
        required=True,
        type=Path,
        help="path to scripts/release-ordering.sh",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("discover", "plan"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument(
            "--input",
            default="-",
            help="JSON input path, or '-' for standard input",
        )
    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("--repository", required=True)
    identity_parser.add_argument("--version", required=True)
    identity_parser.add_argument("--default-branch", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    semver = SemVer(args.ordering_script)
    if args.command == "identity":
        print(
            certificate_identity(
                args.repository, args.version, args.default_branch, semver
            )
        )
        return 0

    value = load_json(args.input)
    if args.command == "discover":
        write_json(discover_exact_tags(value, semver))
    else:
        write_json(compute_plan(value, semver))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReconciliationError as exc:
        print(f"reconcile-release-tags: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
