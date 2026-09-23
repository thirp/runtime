#!/usr/bin/env bash
# Build macOS binaries for thirp-runtime.
#   scripts/build_macos.sh           # all CLIs + libthirp.dylib (local convenience)
#   scripts/build_macos.sh dataplane # agent, caller, libthirp.dylib only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="all"
if [[ "${1:-}" == "dataplane" ]]; then
	MODE="dataplane"
elif [[ -n "${1:-}" ]]; then
	echo "build_macos: unknown mode: ${1} (use all or dataplane)" >&2
	exit 1
fi

if [[ ! -f VERSION.txt ]]; then
	echo "release: VERSION.txt is missing" >&2
	exit 1
fi

VERSION="$(tr -d '[:space:]' < VERSION.txt)"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
ARCH="$(uname -m)"

echo "Building thirp-runtime ${VERSION} for macOS ${ARCH} (${MODE})..."

if ! command -v odin >/dev/null 2>&1; then
	echo "Error: odin compiler not found. Install from https://odin-lang.org/" >&2
	exit 1
fi

if ! command -v brew >/dev/null 2>&1 || ! brew list openssl@3 >/dev/null 2>&1; then
	echo "Error: OpenSSL 3 not found. Install with: brew install openssl@3" >&2
	exit 1
fi

OPENSSL_PREFIX="$(brew --prefix openssl@3)"
OPENSSL_LIB="${OPENSSL_PREFIX}/lib"

OUT="${ROOT}/dist/thirp-runtime-macos-${ARCH}-${VERSION}"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building binaries..."
if [[ "$MODE" == "all" ]]; then
	odin build broker_cli -out:"${OUT}/thirp-broker" -define:THIRP_COMMIT="\"${COMMIT}\"" -extra-linker-flags:"-L${OPENSSL_LIB}"
	odin build web_ingress_cli -out:"${OUT}/thirp-web-ingress" -define:THIRP_COMMIT="\"${COMMIT}\"" -extra-linker-flags:"-L${OPENSSL_LIB}"
fi
odin build agent_cli -out:"${OUT}/thirp-agent" -define:THIRP_COMMIT="\"${COMMIT}\"" -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build caller_cli -out:"${OUT}/thirp-connect" -define:THIRP_COMMIT="\"${COMMIT}\"" -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build c_abi -build-mode:shared -out:"${OUT}/libthirp.dylib" -extra-linker-flags:"-L${OPENSSL_LIB}"

cp "${ROOT}/c_abi/thirp.h" "${OUT}/thirp.h"
cp "${ROOT}/LICENSE" "${OUT}/LICENSE"
cp "${ROOT}/NOTICE" "${OUT}/NOTICE"

echo "macOS binaries built in ${OUT}"
echo ""
if [[ "$MODE" == "all" ]]; then
	"${OUT}/thirp-broker" --version
else
	"${OUT}/thirp-agent" --version
	"${OUT}/thirp-connect" --version
fi
