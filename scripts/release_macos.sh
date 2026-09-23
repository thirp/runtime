#!/usr/bin/env bash
# Build a macOS data-plane release tree: thirp-agent, thirp-connect,
# libthirp.dylib, docs, provenance, SHA-256 checksums, optional GPG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=release_common.sh
source "${ROOT}/scripts/release_common.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "release_macos: must run on macOS (got $(uname -s))" >&2
	exit 1
fi

release_read_version
release_git_state
release_require_odin

if ! command -v brew >/dev/null 2>&1; then
	echo "release_macos: Homebrew is required (brew install openssl@3)" >&2
	exit 1
fi
if ! brew list openssl@3 >/dev/null 2>&1; then
	echo "release_macos: OpenSSL 3 not found. Install with: brew install openssl@3" >&2
	exit 1
fi

OPENSSL_PREFIX="$(brew --prefix openssl@3)"
OPENSSL_LIB="${OPENSSL_PREFIX}/lib"
OPENSSL_VER="$(openssl version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
ARCH="$(uname -m)"
DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

OUT="${ROOT}/dist/thirp-runtime-macos-${ARCH}-${VERSION}"
ARCHIVE="${ROOT}/dist/thirp-runtime-macos-${ARCH}-${VERSION}.tar.gz"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "release_macos: building ${VERSION} commit ${COMMIT} (${WORKTREE}) ${ARCH}"
bash "${ROOT}/scripts/build_macos.sh" dataplane

if [[ ! -x "${OUT}/thirp-agent" || ! -x "${OUT}/thirp-connect" || ! -f "${OUT}/libthirp.dylib" ]]; then
	echo "release_macos: build_macos.sh dataplane did not produce required binaries in ${OUT}" >&2
	exit 1
fi

release_copy_dataplane_docs "$OUT"
release_write_dataplane_provenance "$OUT" "darwin ${ARCH}" "scripts/release_macos.sh" "$OPENSSL_VER" "$DATE"

if [[ -n "${THIRP_MACOS_CODESIGN_IDENTITY:-}" ]]; then
	for bin in thirp-agent thirp-connect libthirp.dylib; do
		codesign --force --options runtime --timestamp \
			--sign "${THIRP_MACOS_CODESIGN_IDENTITY}" "${OUT}/${bin}"
		codesign --verify --verbose "${OUT}/${bin}"
	done
	echo "release_macos: signed with Developer ID ${THIRP_MACOS_CODESIGN_IDENTITY}"
	if [[ -n "${THIRP_MACOS_NOTARY_PROFILE:-}" ]]; then
		ditto -c -k --keepParent "$OUT" "${OUT}.zip"
		xcrun notarytool submit "${OUT}.zip" --keychain-profile "${THIRP_MACOS_NOTARY_PROFILE}" --wait
		xcrun stapler staple "${OUT}/thirp-agent" || true
		rm -f "${OUT}.zip"
	else
		echo "release_macos: notarization skipped (set THIRP_MACOS_NOTARY_PROFILE after storing notarytool credentials)"
	fi
else
	echo "release_macos: Apple Developer ID not set (THIRP_MACOS_CODESIGN_IDENTITY); binaries are unsigned"
fi

(
	cd "$OUT"
	shasum -a 256 \
		thirp-agent \
		thirp-connect \
		libthirp.dylib \
		thirp.h \
		LICENSE \
		NOTICE \
		CHANGELOG.md \
		DEPENDENCIES.md \
		PROVENANCE.txt \
		> SHA256SUMS
)

release_sign_sha256sums "${OUT}/SHA256SUMS"
bash "${ROOT}/scripts/verify_dataplane_release.sh" "$OUT" darwin
release_check_cli_version "${OUT}/thirp-agent"
release_check_cli_version "${OUT}/thirp-connect"

tar -C "$(dirname "$OUT")" -czf "$ARCHIVE" "$(basename "$OUT")"
echo "release_macos: wrote ${OUT}"
echo "release_macos: wrote ${ARCHIVE}"
