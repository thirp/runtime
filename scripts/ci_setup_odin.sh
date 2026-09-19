#!/usr/bin/env bash
# Install or verify Odin for CI (Linux/macOS). Honors ODIN_TAG (default
# dev-2026-07, matching docs/DEPENDENCIES.md) and optional ODIN_RELEASE_URL.
set -euo pipefail

ODIN_TAG="${ODIN_TAG:-dev-2026-07}"
MIN_ODIN_MONTH="${MIN_ODIN_MONTH:-2026-07}"
INSTALL_DIR="${ODIN_INSTALL_DIR:-${HOME}/.local/odin}"

odin_month_ok() {
	local ver
	ver="$(odin version 2>&1 | tr '\n' ' ')"
	if [[ "$ver" =~ dev-([0-9]{4}-[0-9]{2}) ]]; then
		[[ "${BASH_REMATCH[1]}" < "$MIN_ODIN_MONTH" ]] && return 1
		return 0
	fi
	return 1
}

if command -v odin >/dev/null 2>&1 && odin_month_ok; then
	echo "ci_setup_odin: using existing $(command -v odin) ($(odin version 2>&1 | tr '\n' ' '))"
	exit 0
fi

mkdir -p "$INSTALL_DIR"
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
arm64 | aarch64) ODIN_ARCH="arm64" ;;
x86_64 | amd64) ODIN_ARCH="amd64" ;;
*)
	echo "ci_setup_odin: unsupported arch ${ARCH}" >&2
	exit 1
	;;
esac

download_release() {
	local url="$1"
	local dest="$2"
	echo "ci_setup_odin: downloading ${url}"
	curl -fsSL -o "$dest" "$url"
}

unpack_and_path() {
	local archive="$1"
	rm -rf "${INSTALL_DIR}/tree"
	mkdir -p "${INSTALL_DIR}/tree"
	case "$archive" in
	*.zip)
		unzip -q "$archive" -d "${INSTALL_DIR}/tree"
		;;
	*.tar.gz | *.tgz)
		tar -C "${INSTALL_DIR}/tree" -xzf "$archive"
		;;
	*)
		echo "ci_setup_odin: unknown archive type: ${archive}" >&2
		return 1
		;;
	esac
	local found
	found="$(find "${INSTALL_DIR}/tree" -type f -name odin -perm -111 | head -n 1)"
	if [[ -z "$found" ]]; then
		echo "ci_setup_odin: archive did not contain an odin binary" >&2
		return 1
	fi
	echo "$(dirname "$found")"
}

BIN_DIR=""
if [[ -n "${ODIN_RELEASE_URL:-}" ]]; then
	TMP="${INSTALL_DIR}/odin-release.download"
	download_release "$ODIN_RELEASE_URL" "$TMP"
	BIN_DIR="$(unpack_and_path "$TMP")"
else
	case "$OS" in
	Darwin)
		CANDIDATES=(
			"https://github.com/odin-lang/Odin/releases/download/${ODIN_TAG}/odin-macos-${ODIN_ARCH}-${ODIN_TAG}.zip"
			"https://github.com/odin-lang/Odin/releases/download/${ODIN_TAG}/macos-${ODIN_ARCH}.zip"
		)
		;;
	Linux)
		CANDIDATES=(
			"https://github.com/odin-lang/Odin/releases/download/${ODIN_TAG}/odin-linux-${ODIN_ARCH}-${ODIN_TAG}.zip"
			"https://github.com/odin-lang/Odin/releases/download/${ODIN_TAG}/linux-${ODIN_ARCH}.zip"
		)
		;;
	*)
		echo "ci_setup_odin: unsupported OS ${OS}" >&2
		exit 1
		;;
	esac
	TMP="${INSTALL_DIR}/odin-release.download"
	ok=0
	for url in "${CANDIDATES[@]}"; do
		if download_release "$url" "$TMP"; then
			if BIN_DIR="$(unpack_and_path "$TMP")"; then
				ok=1
				break
			fi
		fi
	done
	if [[ "$ok" -ne 1 ]]; then
		echo "ci_setup_odin: release download failed; building ${ODIN_TAG} from source" >&2
		SRC="${INSTALL_DIR}/src"
		rm -rf "$SRC"
		git clone --depth 1 --branch "$ODIN_TAG" https://github.com/odin-lang/Odin.git "$SRC"
		if [[ "$OS" == "Darwin" ]]; then
			if command -v brew >/dev/null 2>&1; then
				brew list llvm >/dev/null 2>&1 || brew install llvm
			fi
		fi
		make -C "$SRC" release
		BIN_DIR="$SRC"
	fi
fi

if [[ -z "${GITHUB_PATH:-}" ]]; then
	echo "ci_setup_odin: add ${BIN_DIR} to PATH"
	export PATH="${BIN_DIR}:${PATH}"
else
	echo "$BIN_DIR" >> "$GITHUB_PATH"
	export PATH="${BIN_DIR}:${PATH}"
fi

if ! command -v odin >/dev/null 2>&1; then
	echo "ci_setup_odin: odin still not on PATH" >&2
	exit 1
fi
if ! odin_month_ok; then
	echo "ci_setup_odin: installed Odin is older than dev-${MIN_ODIN_MONTH}: $(odin version 2>&1)" >&2
	exit 1
fi
echo "ci_setup_odin: $(command -v odin) ($(odin version 2>&1 | tr '\n' ' '))"
