#!/usr/bin/env bash
# Verify a macOS or Windows data-plane release tree.
# Usage: scripts/verify_dataplane_release.sh OUT_DIR darwin|windows
set -euo pipefail

OUT="${1:-}"
PLATFORM="${2:-}"

usage() {
	echo "usage: $0 OUT_DIR darwin|windows" >&2
	exit 1
}

if [[ -z "$OUT" || -z "$PLATFORM" ]]; then
	usage
fi
if [[ ! -d "$OUT" ]]; then
	echo "verify_dataplane_release: missing directory: ${OUT}" >&2
	exit 1
fi

case "$PLATFORM" in
darwin)
	BINS=(thirp-agent thirp-connect libthirp.dylib)
	FORBIDDEN=(thirp-broker thirp-web-ingress thirp-broker.exe thirp-web-ingress.exe libthirp.so libthirp.dll)
	;;
windows)
	BINS=(thirp-agent.exe thirp-connect.exe libthirp.dll)
	FORBIDDEN=(thirp-broker thirp-web-ingress thirp-broker.exe thirp-web-ingress.exe libthirp.so libthirp.dylib)
	;;
*)
	echo "verify_dataplane_release: platform must be darwin or windows, got: ${PLATFORM}" >&2
	exit 1
	;;
esac

DOCS=(thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md PROVENANCE.txt SHA256SUMS)
REQUIRED=("${BINS[@]}" "${DOCS[@]}")

fail=0
for f in "${REQUIRED[@]}"; do
	if [[ ! -f "${OUT}/${f}" ]]; then
		echo "verify_dataplane_release: missing ${f}" >&2
		fail=1
	fi
done
for f in "${FORBIDDEN[@]}"; do
	if [[ -e "${OUT}/${f}" ]]; then
		echo "verify_dataplane_release: data-plane tree must not contain ${f}" >&2
		fail=1
	fi
done

if [[ -f "${OUT}/PROVENANCE.txt" ]]; then
	for field in name version source_commit target artifact_kind components build_command; do
		if ! tr -d '\r' < "${OUT}/PROVENANCE.txt" | grep -q "^${field}:"; then
			echo "verify_dataplane_release: PROVENANCE.txt missing ${field}" >&2
			fail=1
		fi
	done
	if ! tr -d '\r' < "${OUT}/PROVENANCE.txt" | grep -q '^artifact_kind: dataplane$'; then
		echo "verify_dataplane_release: PROVENANCE.txt artifact_kind must be dataplane" >&2
		fail=1
	fi
fi

if [[ -f "${OUT}/SHA256SUMS" ]]; then
	for f in "${BINS[@]}" thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md PROVENANCE.txt; do
		if ! tr -d '\r' < "${OUT}/SHA256SUMS" | awk '{print $2}' | grep -qx "$f"; then
			echo "verify_dataplane_release: SHA256SUMS missing ${f}" >&2
			fail=1
		fi
	done
	if tr -d '\r' < "${OUT}/SHA256SUMS" | grep -qE 'thirp-broker|thirp-web-ingress'; then
		echo "verify_dataplane_release: SHA256SUMS lists a non-data-plane binary" >&2
		fail=1
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sums_check="$(mktemp)"
		tr -d '\r' < "${OUT}/SHA256SUMS" > "$sums_check"
		if ! (cd "$OUT" && sha256sum -c "$sums_check"); then
			echo "verify_dataplane_release: SHA256SUMS check failed" >&2
			fail=1
		fi
		rm -f "$sums_check"
	fi
fi

if [[ -f "${OUT}/SHA256SUMS.asc" ]]; then
	if command -v gpg >/dev/null 2>&1; then
		if ! gpg --verify "${OUT}/SHA256SUMS.asc" "${OUT}/SHA256SUMS" >/dev/null 2>&1; then
			echo "verify_dataplane_release: SHA256SUMS.asc did not verify (import the Thirp publish key)" >&2
			fail=1
		fi
	else
		echo "verify_dataplane_release: SHA256SUMS.asc present but gpg is not installed"
	fi
fi

if [[ "$fail" -ne 0 ]]; then
	echo "verify_dataplane_release: FAIL ${OUT}" >&2
	exit 1
fi
echo "verify_dataplane_release: ok ${PLATFORM} ${OUT}"
