#!/usr/bin/env bash
# Stage the Agent/Caller SDK tree and pack thirp-runtime-sdk-<VERSION>.tar.gz.
# Invoked by scripts/release.sh after operator artifacts exist in $OUT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sdk_lib.sh
source "${SCRIPT_DIR}/sdk_lib.sh"

if [[ -z "${ROOT:-}" ]]; then
	ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
if [[ -z "${VERSION:-}" ]]; then
	VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION.txt")"
fi
if [[ -z "${OUT:-}" ]]; then
	OUT="${ROOT}/dist/thirp-runtime-${VERSION}"
fi
if [[ -z "${ARCH:-}" ]]; then
	ARCH="$(uname -m)"
fi
if [[ -z "${DATE:-}" ]]; then
	DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi

STAGE="${ROOT}/dist/thirp-runtime-sdk-${VERSION}"
SDK_NAME="thirp-runtime-sdk-${VERSION}"
C_TARGET="linux-${ARCH}"

if [[ ! -f "${OUT}/libthirp.so" ]]; then
	echo "release_sdk: missing ${OUT}/libthirp.so" >&2
	exit 1
fi
if [[ ! -f "${OUT}/thirp.h" ]]; then
	echo "release_sdk: missing ${OUT}/thirp.h" >&2
	exit 1
fi
if [[ ! -f "${ROOT}/docs/SDK.md" ]]; then
	echo "release_sdk: missing docs/SDK.md" >&2
	exit 1
fi

rm -rf "$STAGE"
mkdir -p "${STAGE}/odin/thirp"
mkdir -p "${STAGE}/c/include"
mkdir -p "${STAGE}/c/lib/${C_TARGET}"
mkdir -p "${STAGE}/examples/odin"
mkdir -p "${STAGE}/examples/c"
mkdir -p "${STAGE}/docs"

echo "release_sdk: walking Agent/Caller import closure"
mapfile -t PACKAGES < <(sdk_walk_packages "$ROOT")
for pkg in "${PACKAGES[@]}"; do
	sdk_copy_package_sources "$ROOT" "${STAGE}/odin/thirp" "$pkg"
done

cp "${OUT}/thirp.h" "${STAGE}/c/include/thirp.h"
cp "${OUT}/libthirp.so" "${STAGE}/c/lib/${C_TARGET}/libthirp.so"

cp -a "${ROOT}/examples/sdk/odin/ephemeral_host" "${STAGE}/examples/odin/ephemeral_host"
cp -a "${ROOT}/examples/sdk/odin/join_code_client" "${STAGE}/examples/odin/join_code_client"
cp -a "${ROOT}/examples/sdk/c/echo_client" "${STAGE}/examples/c/echo_client"

cp "${ROOT}/docs/SDK.md" "${STAGE}/docs/SDK.md"
cp "${ROOT}/docs/sdk-public-api.txt" "${STAGE}/docs/sdk-public-api.txt"
cp "${ROOT}/docs/COMPATIBILITY.md" "${STAGE}/docs/COMPATIBILITY.md"
cp "${ROOT}/docs/PROTOCOL.md" "${STAGE}/docs/PROTOCOL.md"
cp "${ROOT}/LICENSE" "${STAGE}/LICENSE"
cp "${ROOT}/NOTICE" "${STAGE}/NOTICE"
cp "${ROOT}/VERSION.txt" "${STAGE}/VERSION.txt"
cp "${OUT}/thirp-runtime-${VERSION}.spdx.json" "${STAGE}/thirp-runtime-${VERSION}.spdx.json"
cp "${OUT}/PROVENANCE.txt" "${STAGE}/PROVENANCE.txt"

PROTOCOL_VERSION="$(sdk_read_protocol_version "$ROOT")"
ODIN_MIN="$(sdk_read_odin_min_version "$ROOT")"

sdk_write_manifest() {
	local manifest="${STAGE}/SDK_MANIFEST.json"
	local list rel size hash first

	list="$(mktemp)"
	(
		cd "$STAGE"
		find . -type f ! -name SDK_MANIFEST.json ! -name SHA256SUMS | sed 's|^\./||' | sort
	) >"$list"

	{
		echo '{'
		echo '  "manifest_version": 1,'
		echo "  \"project\": \"thirp-runtime\","
		echo "  \"project_version\": \"$(sdk_json_escape "$VERSION")\","
		echo "  \"protocol_version\": \"$(sdk_json_escape "$PROTOCOL_VERSION")\","
		echo "  \"odin_min_version\": \"$(sdk_json_escape "$ODIN_MIN")\","
		echo '  "odin_collection_root": "odin/thirp",'
		echo '  "public_packages": ["agent", "caller"],'
		echo '  "support_packages": ["protocol", "transport", "logging"],'
		echo '  "c_abi": {'
		echo '    "header": "c/include/thirp.h",'
		echo '    "libraries": ['
		echo "      {\"target\": \"$(sdk_json_escape "$C_TARGET")\", \"path\": \"c/lib/$(sdk_json_escape "$C_TARGET")/libthirp.so\"}"
		echo '    ]'
		echo '  },'
		echo '  "examples": ['
		echo '    "examples/odin/ephemeral_host",'
		echo '    "examples/odin/join_code_client",'
		echo '    "examples/c/echo_client"'
		echo '  ],'
		echo '  "files": ['
		first=1
		while IFS= read -r rel; do
			[[ -z "$rel" ]] && continue
			size="$(stat -c %s "${STAGE}/${rel}")"
			hash="$(sha256sum "${STAGE}/${rel}" | awk '{print $1}')"
			if [[ $first -eq 0 ]]; then
				printf ',\n'
			fi
			first=0
			printf '    {"path": "%s", "size": %s, "sha256": "%s"}' "$(sdk_json_escape "$rel")" "$size" "$hash"
		done <"$list"
		echo
		echo '  ]'
		echo '}'
	} >"$manifest"
	rm -f "$list"
}

sdk_write_manifest

(
	cd "$STAGE"
	find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs -d '\n' sha256sum >SHA256SUMS
)

TAR="${OUT}/${SDK_NAME}.tar.gz"
rm -f "$TAR"
tar --sort=name --mtime="$DATE" --owner=0 --group=0 --numeric-owner \
	-C "${ROOT}/dist" -czf "$TAR" "$SDK_NAME"

echo "release_sdk: wrote ${TAR}"
