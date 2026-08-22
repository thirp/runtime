# Shared SDK package-closure helpers. Sourced by release_sdk.sh, release_broker.sh,
# check_sdk_api.sh, verify_sdk.sh, and verify_broker.sh.
# Allowed Agent/Caller compile closure. A new package in the walk is a release failure.

SDK_ALLOWED_PACKAGES="agent caller protocol transport logging"
SDK_PUBLIC_PACKAGES="agent caller"
SDK_SUPPORT_PACKAGES="protocol transport logging"
SDK_FORBIDDEN_PACKAGES="auth broker broker_cli agent_cli caller_cli c_abi config echo_cli echo_http_cli version web_ingress web_ingress_cli"

# Broker tarball: embed SDK Odin packages plus auth and broker. No third foundation artifact.
BROKER_ALLOWED_PACKAGES="agent caller protocol transport logging auth broker"
BROKER_PUBLIC_PACKAGES="agent caller auth broker"
BROKER_SUPPORT_PACKAGES="protocol transport logging"
BROKER_FORBIDDEN_PACKAGES="broker_cli agent_cli caller_cli c_abi config echo_cli echo_http_cli version web_ingress web_ingress_cli"

sdk_is_compiler_import() {
	case "$1" in
	core:* | base:* | vendor:*)
		return 0
		;;
	esac
	return 1
}

sdk_package_from_import() {
	local path="$1"
	if [[ "$path" == thirp:* ]]; then
		path="${path#thirp:}"
	fi
	printf '%s\n' "${path##*/}"
}

sdk_extract_import_paths() {
	local file="$1"
	grep -E '^[[:space:]]*import[[:space:]]' "$file" | sed -n 's/.*"\([^"]*\)".*/\1/p'
}

sdk_is_sdk_source() {
	local base
	base="$(basename "$1")"
	if [[ "$base" == *_test.odin ]]; then
		return 1
	fi
	if [[ "$base" == test_helpers.odin ]]; then
		return 1
	fi
	return 0
}

sdk_list_contains() {
	local pkg="$1"
	local item
	shift
	for item in "$@"; do
		if [[ "$pkg" == "$item" ]]; then
			return 0
		fi
	done
	return 1
}

sdk_package_allowed() {
	sdk_list_contains "$1" $SDK_ALLOWED_PACKAGES
}

broker_package_allowed() {
	sdk_list_contains "$1" $BROKER_ALLOWED_PACKAGES
}

# Walk non-test imports from the given start packages. allowed is a space-separated
# package list. Prints that list in declared order. ROOT is the repository root.
sdk_walk_allowed_packages() {
	local root="$1"
	local allowed="$2"
	local label="$3"
	shift 3
	local -A seen=()
	local -a queue=("$@")
	local pkg file path dep item

	while [[ ${#queue[@]} -gt 0 ]]; do
		pkg="${queue[0]}"
		queue=("${queue[@]:1}")
		if [[ -n "${seen[$pkg]:-}" ]]; then
			continue
		fi
		if ! sdk_list_contains "$pkg" $allowed; then
			echo "sdk: unexpected package in ${label} closure: ${pkg}" >&2
			return 1
		fi
		if [[ ! -d "${root}/${pkg}" ]]; then
			echo "sdk: missing package directory: ${pkg}" >&2
			return 1
		fi
		seen["$pkg"]=1
		for file in "${root}/${pkg}"/*.odin; do
			if [[ ! -f "$file" ]]; then
				continue
			fi
			if ! sdk_is_sdk_source "$file"; then
				continue
			fi
			while IFS= read -r path; do
				[[ -z "$path" ]] && continue
				if sdk_is_compiler_import "$path"; then
					continue
				fi
				dep="$(sdk_package_from_import "$path")"
				if [[ -z "$dep" ]]; then
					continue
				fi
				if [[ -z "${seen[$dep]:-}" ]]; then
					queue+=("$dep")
				fi
			done < <(sdk_extract_import_paths "$file")
		done
	done

	for item in $allowed; do
		if [[ -z "${seen[$item]:-}" ]]; then
			echo "sdk: expected package missing from import walk: ${item}" >&2
			return 1
		fi
	done

	for pkg in $allowed; do
		printf '%s\n' "$pkg"
	done
}

# Walk non-test imports starting at agent/ and caller/. Prints package names.
sdk_walk_packages() {
	sdk_walk_allowed_packages "$1" "$SDK_ALLOWED_PACKAGES" "Agent/Caller" agent caller
}

# Walk from broker/, then agent/ and caller/ so one collection compiles both.
broker_walk_packages() {
	sdk_walk_allowed_packages "$1" "$BROKER_ALLOWED_PACKAGES" "Broker" broker agent caller
}

sdk_copy_package_sources() {
	local root="$1"
	local dest="$2"
	local pkg="$3"
	local file base

	mkdir -p "${dest}/${pkg}"
	for file in "${root}/${pkg}"/*.odin; do
		if [[ ! -f "$file" ]]; then
			continue
		fi
		if ! sdk_is_sdk_source "$file"; then
			continue
		fi
		base="$(basename "$file")"
		cp "$file" "${dest}/${pkg}/${base}"
	done
}

sdk_read_protocol_version() {
	local root="$1"
	local major minor
	major="$(sed -n 's/^PROTOCOL_MAJOR :: u8(\([0-9]*\)).*/\1/p' "${root}/protocol/values.odin")"
	minor="$(sed -n 's/^PROTOCOL_MINOR :: u8(\([0-9]*\)).*/\1/p' "${root}/protocol/values.odin")"
	if [[ -z "$major" || -z "$minor" ]]; then
		echo "sdk: could not parse PROTOCOL_MAJOR/MINOR" >&2
		return 1
	fi
	printf '%s.%s\n' "$major" "$minor"
}

sdk_read_odin_min_version() {
	local root="$1"
	local ver
	ver="$(grep -oE 'dev-[0-9]{4}-[0-9]{2}' "${root}/docs/DEPENDENCIES.md" | head -n1)"
	if [[ -z "$ver" ]]; then
		echo "sdk: could not parse odin_min_version from docs/DEPENDENCIES.md" >&2
		return 1
	fi
	printf '%s\n' "$ver"
}

sdk_json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sdk_json_string_array() {
	local first=1 item
	printf '['
	for item in "$@"; do
		if [[ $first -eq 0 ]]; then
			printf ', '
		fi
		first=0
		printf '"%s"' "$(sdk_json_escape "$item")"
	done
	printf ']'
}
