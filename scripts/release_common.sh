#!/usr/bin/env bash
# Shared helpers for Linux and macOS release scripts.
# Source this file; do not execute it.
# Keep THIRP_PUBLISH_GPG_FINGERPRINT in sync with docs/SECURITY.md.

THIRP_PUBLISH_GPG_FINGERPRINT="3B8559D8754FB3C5B21110C786897A405CF3D8C4"
# Keep in sync with docs/DEPENDENCIES.md Minimum.
MIN_ODIN_MONTH="2026-07"

release_read_version() {
	if [[ ! -f "${ROOT}/VERSION.txt" ]]; then
		echo "release: VERSION.txt is missing" >&2
		exit 1
	fi
	VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION.txt")"
	if [[ ! "$VERSION" =~ ^0\.[0-9]+\.[0-9]+$ ]]; then
		echo "release: VERSION.txt must be 0.x.y, got: ${VERSION}" >&2
		exit 1
	fi
}

release_git_state() {
	COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
	WORKTREE="clean"
	if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
			WORKTREE="dirty"
		fi
	fi
}

release_require_odin() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "release: odin compiler not found" >&2
		exit 1
	fi
	ODIN_VER="$(odin version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
	if [[ "$ODIN_VER" =~ dev-([0-9]{4}-[0-9]{2}) ]]; then
		local odin_month="${BASH_REMATCH[1]}"
		if [[ "$odin_month" < "$MIN_ODIN_MONTH" ]]; then
			echo "release: Odin ${ODIN_VER} is older than minimum dev-${MIN_ODIN_MONTH}" >&2
			exit 1
		fi
	else
		echo "release: could not parse Odin month from: ${ODIN_VER}" >&2
		exit 1
	fi
}

release_sign_sha256sums() {
	local sums="${1:-}"
	if [[ -z "$sums" || ! -f "$sums" ]]; then
		echo "release: SHA256SUMS missing: ${sums:-<empty>}" >&2
		exit 1
	fi
	if [[ -z "${THIRP_GPG_KEY:-}" ]]; then
		if command -v gpg >/dev/null 2>&1 &&
			gpg --list-secret-keys --with-colons "$THIRP_PUBLISH_GPG_FINGERPRINT" >/dev/null 2>&1; then
			THIRP_GPG_KEY="$THIRP_PUBLISH_GPG_FINGERPRINT"
		fi
	fi
	if [[ -z "${THIRP_GPG_KEY:-}" ]]; then
		echo "release: GPG signatures not produced (publish key not in the agent; set THIRP_GPG_KEY)"
		return 0
	fi
	if [[ -f "${ROOT}/docs/SECURITY.md" ]] &&
		! grep -q "$THIRP_PUBLISH_GPG_FINGERPRINT" "${ROOT}/docs/SECURITY.md"; then
		echo "release: signing fingerprint does not match docs/SECURITY.md" >&2
		exit 1
	fi
	gpg --detach-sign --armor --local-user "${THIRP_GPG_KEY}" \
		--output "${sums}.asc" "$sums"
	gpg --verify "${sums}.asc" "$sums"
	echo "release: signed SHA256SUMS with ${THIRP_GPG_KEY}"
}

release_write_dataplane_provenance() {
	local out="$1"
	local target="$2"
	local build_command="$3"
	local openssl_ver="$4"
	local date_utc="$5"
	cat > "${out}/PROVENANCE.txt" <<EOF
name: thirp-runtime
version: ${VERSION}
source_commit: ${COMMIT}
worktree: ${WORKTREE}
odin: ${ODIN_VER}
openssl: ${openssl_ver}
target: ${target}
artifact_kind: dataplane
components: thirp-agent thirp-connect libthirp
build_command: ${build_command}
built_at: ${date_utc}
EOF
}

release_copy_dataplane_docs() {
	local out="$1"
	cp "${ROOT}/c_abi/thirp.h" "${out}/thirp.h"
	cp "${ROOT}/LICENSE" "${out}/LICENSE"
	cp "${ROOT}/NOTICE" "${out}/NOTICE"
	cp "${ROOT}/docs/CHANGELOG.md" "${out}/CHANGELOG.md"
	cp "${ROOT}/docs/DEPENDENCIES.md" "${out}/DEPENDENCIES.md"
}

release_check_cli_version() {
	local bin="$1"
	local ver
	ver="$("$bin" --version)"
	echo "release: ${ver}"
	if [[ "$ver" != *"${VERSION}"* ]]; then
		echo "release: --version missing ${VERSION}: ${ver}" >&2
		exit 1
	fi
	if [[ "$COMMIT" != "unknown" && "$ver" != *"${COMMIT}"* ]]; then
		echo "release: --version missing commit ${COMMIT}: ${ver}" >&2
		exit 1
	fi
}
