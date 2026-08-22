#!/usr/bin/env bash
# Check SDK public API inventory and Agent/Caller package boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=sdk_lib.sh
source "${SCRIPT_DIR}/sdk_lib.sh"

INVENTORY="${ROOT}/docs/sdk-public-api.txt"
HEADER="${ROOT}/c_abi/thirp.h"

if [[ ! -f "$INVENTORY" ]]; then
	echo "check_sdk_api: missing ${INVENTORY}" >&2
	exit 1
fi

echo "check_sdk_api: import closure"
sdk_walk_packages "$ROOT" >/dev/null
broker_walk_packages "$ROOT" >/dev/null

echo "check_sdk_api: forbidden imports in SDK sources"
for pkg in $SDK_ALLOWED_PACKAGES; do
	for file in "${ROOT}/${pkg}"/*.odin; do
		[[ -f "$file" ]] || continue
		sdk_is_sdk_source "$file" || continue
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			sdk_is_compiler_import "$path" && continue
			dep="$(sdk_package_from_import "$path")"
			for forbidden in $SDK_FORBIDDEN_PACKAGES; do
				if [[ "$dep" == "$forbidden" ]]; then
					echo "check_sdk_api: ${file} imports forbidden package ${dep}" >&2
					exit 1
				fi
			done
		done < <(sdk_extract_import_paths "$file")
	done
done

echo "check_sdk_api: forbidden imports in Broker collection sources"
for pkg in $BROKER_ALLOWED_PACKAGES; do
	for file in "${ROOT}/${pkg}"/*.odin; do
		[[ -f "$file" ]] || continue
		sdk_is_sdk_source "$file" || continue
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			sdk_is_compiler_import "$path" && continue
			dep="$(sdk_package_from_import "$path")"
			for forbidden in $BROKER_FORBIDDEN_PACKAGES; do
				if [[ "$dep" == "$forbidden" ]]; then
					echo "check_sdk_api: ${file} imports forbidden package ${dep}" >&2
					exit 1
				fi
			done
		done < <(sdk_extract_import_paths "$file")
	done
done

echo "check_sdk_api: examples use collection imports"
for src in \
	"${ROOT}/examples/sdk/odin/ephemeral_host/main.odin" \
	"${ROOT}/examples/sdk/odin/join_code_client/main.odin"; do
	if ! grep -q 'import .* "thirp:agent"\|import .* "thirp:caller"' "$src"; then
		if ! grep -q '"thirp:agent"\|"thirp:caller"' "$src"; then
			echo "check_sdk_api: ${src} does not import thirp:agent or thirp:caller" >&2
			exit 1
		fi
	fi
	if grep -E 'import .*"\.\./' "$src"; then
		echo "check_sdk_api: ${src} uses a relative import" >&2
		exit 1
	fi
done

section=""
fail=0

check_name_in_package() {
	local pkg="$1"
	local kind="$2"
	local name="$3"
	local file
	local pattern

	case "$kind" in
	procs)
		pattern="^${name} :: proc"
		;;
	types)
		pattern="^${name} :: "
		;;
	consts)
		pattern="^${name} :: "
		;;
	*)
		echo "check_sdk_api: unknown kind ${kind}" >&2
		return 1
		;;
	esac

	for file in "${ROOT}/${pkg}"/*.odin; do
		[[ -f "$file" ]] || continue
		sdk_is_sdk_source "$file" || continue
		if grep -qE "$pattern" "$file"; then
			return 0
		fi
	done
	echo "check_sdk_api: missing ${kind} ${pkg}.${name}" >&2
	return 1
}

header_syms="$(grep -oE 'THIRP_API[[:space:]]+[^;(]+[[:space:]]+thirp_[A-Za-z0-9_]+[[:space:]]*\(' "$HEADER" | sed -n 's/.*\(thirp_[A-Za-z0-9_]*\)[[:space:]]*(.*/\1/p' | sort -u)"
inventoried_c=""

while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line%%$'\r'}"
	if [[ -z "$line" || "$line" == \#* ]]; then
		continue
	fi
	if [[ "$line" == \[*\] ]]; then
		section="${line#[}"
		section="${section%]}"
		continue
	fi
	if [[ "$section" == c ]]; then
		inventoried_c+="${line}"$'\n'
		if ! grep -qE "[[:space:]]${line}[[:space:]]*\(" "$HEADER"; then
			echo "check_sdk_api: inventoried C symbol missing from thirp.h: ${line}" >&2
			fail=1
		fi
		continue
	fi
	if [[ "$section" == package\ * ]]; then
		pkg="${section#package }"
		if [[ "$line" == types:* || "$line" == procs:* || "$line" == consts:* ]]; then
			kind="${line%%:*}"
			rest="${line#*:}"
			for name in $rest; do
				if ! check_name_in_package "$pkg" "$kind" "$name"; then
					fail=1
				fi
			done
		fi
	fi
done <"$INVENTORY"

while IFS= read -r sym; do
	[[ -z "$sym" ]] && continue
	if ! grep -qxF "$sym" <<<"$inventoried_c"; then
		echo "check_sdk_api: THIRP_API ${sym} is not in docs/sdk-public-api.txt" >&2
		fail=1
	fi
done <<<"$header_syms"

if [[ $fail -ne 0 ]]; then
	exit 1
fi

echo "check_sdk_api: ok"
