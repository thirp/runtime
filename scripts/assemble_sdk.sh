#!/usr/bin/env bash
# Pack the published embed SDK: one tarball whose c/lib/ holds every
# libthirp built for this version.
#
# Usage: scripts/assemble_sdk.sh ARTIFACT_DIR
#
# ARTIFACT_DIR contains the platform build outputs (the workflow download
# tree, or a fixture):
#   libthirp.so
#   thirp-runtime-macos-arm64-*.tar.gz
#   thirp-runtime-macos-x86_64-*.tar.gz
#   libthirp.dll or thirp-runtime-windows-*.zip
#
# Writes ARTIFACT_DIR/thirp-runtime-sdk-<VERSION>.tar.gz.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="${1:-}"
if [[ -z "$ART" || ! -d "$ART" ]]; then
	echo "assemble_sdk: usage: $0 ARTIFACT_DIR" >&2
	exit 1
fi

find_one() {
	local label="$1"
	shift
	local -a hits=()
	local hit
	while IFS= read -r hit; do
		[[ -n "$hit" ]] && hits+=("$hit")
	done < <(find "$ART" -type f "$@" | LC_ALL=C sort)
	if [[ "${#hits[@]}" -ne 1 ]]; then
		echo "assemble_sdk: expected one ${label}, found ${#hits[@]}" >&2
		printf '  %s\n' "${hits[@]:-}" >&2
		exit 1
	fi
	printf '%s\n' "${hits[0]}"
}

extract_named() {
	local archive="$1"
	local base="$2"
	local dest="$3"
	local tmp found count
	tmp="$(mktemp -d)"
	case "$archive" in
	*.tar.gz | *.tgz)
		tar -C "$tmp" -xzf "$archive"
		;;
	*.zip)
		unzip -q "$archive" -d "$tmp"
		;;
	*)
		echo "assemble_sdk: unsupported archive ${archive}" >&2
		rm -rf "$tmp"
		exit 1
		;;
	esac
	mapfile -t found < <(find "$tmp" -type f -name "$base" | LC_ALL=C sort)
	count="${#found[@]}"
	if [[ "$count" -ne 1 ]]; then
		echo "assemble_sdk: ${archive} contains ${count} ${base}" >&2
		rm -rf "$tmp"
		exit 1
	fi
	mkdir -p "$(dirname "$dest")"
	cp "${found[0]}" "$dest"
	rm -rf "$tmp"
}

SO="$(find_one 'libthirp.so' -name 'libthirp.so')"
MAC_ARM="$(find_one 'macos arm64 archive' -name 'thirp-runtime-macos-arm64-*.tar.gz')"
MAC_X64="$(find_one 'macos x86_64 archive' -name 'thirp-runtime-macos-x86_64-*.tar.gz')"

mapfile -t DLLS < <(find "$ART" -type f -name 'libthirp.dll' | LC_ALL=C sort)
if [[ "${#DLLS[@]}" -eq 1 ]]; then
	DLL="${DLLS[0]}"
elif [[ "${#DLLS[@]}" -eq 0 ]]; then
	WIN_ZIP="$(find_one 'windows archive' -name 'thirp-runtime-windows-*.zip')"
	DLL=""
else
	echo "assemble_sdk: expected one libthirp.dll, found ${#DLLS[@]}" >&2
	exit 1
fi

VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION.txt")"
SDK_NAME="thirp-runtime-sdk-${VERSION}"
WORK="$(mktemp -d)"
cleanup() {
	rm -rf "$WORK"
}
trap cleanup EXIT

LIBROOT="${WORK}/libs"
mkdir -p \
	"${LIBROOT}/linux-x86_64" \
	"${LIBROOT}/darwin-arm64" \
	"${LIBROOT}/darwin-x86_64" \
	"${LIBROOT}/windows-amd64"
cp "$SO" "${LIBROOT}/linux-x86_64/libthirp.so"
extract_named "$MAC_ARM" libthirp.dylib "${LIBROOT}/darwin-arm64/libthirp.dylib"
extract_named "$MAC_X64" libthirp.dylib "${LIBROOT}/darwin-x86_64/libthirp.dylib"
if [[ -n "$DLL" ]]; then
	cp "$DLL" "${LIBROOT}/windows-amd64/libthirp.dll"
else
	extract_named "$WIN_ZIP" libthirp.dll "${LIBROOT}/windows-amd64/libthirp.dll"
fi

export ROOT VERSION
export SDK_LIB_ROOT="$LIBROOT"
export SDK_COMPLETE=1
export SDK_BUILD_COMMAND="scripts/assemble_sdk.sh"
export SDK_STAGE="${WORK}/${SDK_NAME}"
export OUT="${WORK}/out"
bash "${ROOT}/scripts/release_sdk.sh"
cp "${OUT}/${SDK_NAME}.tar.gz" "${ART}/${SDK_NAME}.tar.gz"
echo "assemble_sdk: wrote ${ART}/${SDK_NAME}.tar.gz"
