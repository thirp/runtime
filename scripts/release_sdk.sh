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

STAGE="${SDK_STAGE:-${ROOT}/dist/thirp-runtime-sdk-${VERSION}}"
SDK_NAME="thirp-runtime-sdk-${VERSION}"

if [[ ! -f "${ROOT}/docs/SDK.md" ]]; then
	echo "release_sdk: missing docs/SDK.md" >&2
	exit 1
fi
if [[ -z "${COMMIT:-}" ]]; then
	COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
fi
if [[ -z "${DATE:-}" ]]; then
	DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi

rm -rf "$STAGE"
mkdir -p "${STAGE}/odin/thirp"
mkdir -p "${STAGE}/c/include"
mkdir -p "${STAGE}/examples/odin"
mkdir -p "${STAGE}/examples/c"
mkdir -p "${STAGE}/docs"

echo "release_sdk: walking Agent/Caller import closure"
mapfile -t PACKAGES < <(sdk_walk_packages "$ROOT")
for pkg in "${PACKAGES[@]}"; do
	sdk_copy_package_sources "$ROOT" "${STAGE}/odin/thirp" "$pkg"
done

HEADER_SRC="${OUT}/thirp.h"
if [[ ! -f "$HEADER_SRC" ]]; then
	HEADER_SRC="${ROOT}/c_abi/thirp.h"
fi
if [[ ! -f "$HEADER_SRC" ]]; then
	echo "release_sdk: missing thirp.h" >&2
	exit 1
fi
cp "$HEADER_SRC" "${STAGE}/c/include/thirp.h"

declare -a STAGED_TARGETS=()
stage_lib() {
	local target="$1"
	local src="$2"
	local name
	name="$(sdk_c_lib_name "$target")" || {
		echo "release_sdk: unknown C ABI target ${target}" >&2
		exit 1
	}
	if [[ ! -f "$src" ]]; then
		echo "release_sdk: missing ${src}" >&2
		exit 1
	fi
	if [[ "$(basename "$src")" != "$name" ]]; then
		echo "release_sdk: ${src} is not ${name}" >&2
		exit 1
	fi
	if [[ ${#STAGED_TARGETS[@]} -gt 0 ]]; then
		local already
		for already in "${STAGED_TARGETS[@]}"; do
			if [[ "$already" == "$target" ]]; then
				echo "release_sdk: duplicate C ABI target ${target}" >&2
				exit 1
			fi
		done
	fi
	mkdir -p "${STAGE}/c/lib/${target}"
	cp "$src" "${STAGE}/c/lib/${target}/${name}"
	STAGED_TARGETS+=("$target")
}

if [[ -n "${SDK_LIB_ROOT:-}" ]]; then
	if [[ ! -d "$SDK_LIB_ROOT" ]]; then
		echo "release_sdk: SDK_LIB_ROOT is not a directory: ${SDK_LIB_ROOT}" >&2
		exit 1
	fi
	found_any=0
	for dir in "$SDK_LIB_ROOT"/*; do
		[[ -d "$dir" ]] || continue
		found_any=1
		target="$(basename "$dir")"
		name="$(sdk_c_lib_name "$target")" || {
			echo "release_sdk: unknown C ABI target ${target}" >&2
			exit 1
		}
		stage_lib "$target" "${dir}/${name}"
	done
	if [[ "$found_any" -eq 0 ]]; then
		echo "release_sdk: SDK_LIB_ROOT has no target directories: ${SDK_LIB_ROOT}" >&2
		exit 1
	fi
else
	if [[ ! -f "${OUT}/libthirp.so" ]]; then
		echo "release_sdk: missing ${OUT}/libthirp.so" >&2
		exit 1
	fi
	stage_lib "linux-${ARCH}" "${OUT}/libthirp.so"
fi

if [[ "${SDK_COMPLETE:-0}" == "1" ]]; then
	for target in "${SDK_C_TARGETS[@]}"; do
		ok=0
		for staged in "${STAGED_TARGETS[@]}"; do
			if [[ "$staged" == "$target" ]]; then
				ok=1
			fi
		done
		if [[ "$ok" -eq 0 ]]; then
			echo "release_sdk: complete SDK missing ${target}" >&2
			exit 1
		fi
	done
	for staged in "${STAGED_TARGETS[@]}"; do
		ok=0
		for target in "${SDK_C_TARGETS[@]}"; do
			if [[ "$staged" == "$target" ]]; then
				ok=1
			fi
		done
		if [[ "$ok" -eq 0 ]]; then
			echo "release_sdk: complete SDK has unexpected target ${staged}" >&2
			exit 1
		fi
	done
fi

ORDERED_TARGETS=()
for target in "${SDK_C_TARGETS[@]}"; do
	for staged in "${STAGED_TARGETS[@]}"; do
		if [[ "$staged" == "$target" ]]; then
			ORDERED_TARGETS+=("$target")
		fi
	done
done
for staged in "${STAGED_TARGETS[@]}"; do
	known=0
	for target in "${SDK_C_TARGETS[@]}"; do
		if [[ "$staged" == "$target" ]]; then
			known=1
		fi
	done
	if [[ "$known" -eq 0 ]]; then
		ORDERED_TARGETS+=("$staged")
	fi
done

cp -a "${ROOT}/examples/sdk/odin/ephemeral_host" "${STAGE}/examples/odin/ephemeral_host"
cp -a "${ROOT}/examples/sdk/odin/join_code_client" "${STAGE}/examples/odin/join_code_client"
cp -a "${ROOT}/examples/sdk/c/echo_client" "${STAGE}/examples/c/echo_client"

SBOM_SRC="${OUT}/thirp-runtime-${VERSION}.spdx.json"
if [[ -f "$SBOM_SRC" ]]; then
	cp "$SBOM_SRC" "${STAGE}/thirp-runtime-${VERSION}.spdx.json"
else
	sed -e "s/__VERSION__/${VERSION}/g" \
		-e "s/__COMMIT__/${COMMIT}/g" \
		-e "s/__DATE__/${DATE}/g" \
		"${ROOT}/scripts/sbom.spdx.json.in" > "${STAGE}/thirp-runtime-${VERSION}.spdx.json"
fi

PROV_SRC="${OUT}/PROVENANCE.txt"
if [[ -f "$PROV_SRC" && -z "${SDK_LIB_ROOT:-}" ]]; then
	cp "$PROV_SRC" "${STAGE}/PROVENANCE.txt"
else
	c_abi_targets="${ORDERED_TARGETS[*]}"
	cat > "${STAGE}/PROVENANCE.txt" <<EOF
name: thirp-runtime
version: ${VERSION}
source_commit: ${COMMIT}
artifact_kind: sdk
c_abi_targets: ${c_abi_targets}
build_command: ${SDK_BUILD_COMMAND:-scripts/release_sdk.sh}
EOF
fi

cp "${ROOT}/docs/SDK.md" "${STAGE}/docs/SDK.md"
cp "${ROOT}/docs/sdk-public-api.txt" "${STAGE}/docs/sdk-public-api.txt"
cp "${ROOT}/docs/COMPATIBILITY.md" "${STAGE}/docs/COMPATIBILITY.md"
cp "${ROOT}/docs/PROTOCOL.md" "${STAGE}/docs/PROTOCOL.md"
cp "${ROOT}/LICENSE" "${STAGE}/LICENSE"
cp "${ROOT}/NOTICE" "${STAGE}/NOTICE"
cp "${ROOT}/VERSION.txt" "${STAGE}/VERSION.txt"

PROTOCOL_VERSION="$(sdk_read_protocol_version "$ROOT")"
ODIN_MIN="$(sdk_read_odin_min_version "$ROOT")"

sdk_write_manifest() {
	local manifest="${STAGE}/SDK_MANIFEST.json"
	local list rel size hash first lib_first lib_name target

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
		lib_first=1
		for target in "${ORDERED_TARGETS[@]}"; do
			lib_name="$(sdk_c_lib_name "$target")"
			if [[ $lib_first -eq 0 ]]; then
				printf ',\n'
			fi
			lib_first=0
			printf '      {"target": "%s", "path": "c/lib/%s/%s"}' \
				"$(sdk_json_escape "$target")" \
				"$(sdk_json_escape "$target")" \
				"$(sdk_json_escape "$lib_name")"
		done
		echo
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

if [[ "$(basename "$STAGE")" != "$SDK_NAME" ]]; then
	echo "release_sdk: stage directory must be named ${SDK_NAME}, got $(basename "$STAGE")" >&2
	exit 1
fi
mkdir -p "$OUT"
TAR="${OUT}/${SDK_NAME}.tar.gz"
rm -f "$TAR"
tar --sort=name --mtime="$DATE" --owner=0 --group=0 --numeric-owner \
	-C "$(dirname "$STAGE")" -czf "$TAR" "$SDK_NAME"

echo "release_sdk: wrote ${TAR}"
