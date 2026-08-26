#!/usr/bin/env bash
# Assemble the public allowlisted Thirp Runtime tree into DEST.
# Also: scripts/stage_public_tree.sh --check-archive FILE.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# New top-level Odin packages must be added here. Silent omission is a failure.
ALLOW_PACKAGES=(
	agent
	agent_cli
	auth
	broker
	broker_cli
	c_abi
	caller
	caller_cli
	config
	echo_cli
	echo_http_cli
	logging
	protocol
	transport
	version
	web_ingress
	web_ingress_cli
)

ALLOW_ROOT_FILES=(
	.gitignore
	all.odin
	ols.json
	LICENSE
	NOTICE
	README.md
	VERSION.txt
)

ALLOW_DOCS=(
	docs/BUILDING.md
	docs/QUICKSTART.md
	docs/AGENTS.md
	docs/CHANGELOG.md
	docs/COMPATIBILITY.md
	docs/DEPENDENCIES.md
	docs/NAMING.md
	docs/OPERATIONS.md
	docs/PROTOCOL.md
	docs/RACES.md
	docs/SDK.md
	docs/SECURITY.md
	docs/TRADEMARKS.md
	docs/sdk-public-api.txt
)

ALLOW_SCRIPTS=(
	scripts/check_sdk_api.sh
	scripts/release.sh
	scripts/release_broker.sh
	scripts/release_sdk.sh
	scripts/sbom.spdx.json.in
	scripts/sdk_lib.sh
	scripts/stage_public_tree.sh
	scripts/verify_broker.sh
	scripts/verify_sdk.sh
)

ALLOW_DEPLOY=(
	deploy/container/Dockerfile
	deploy/systemd/thirp-agent.service
	deploy/systemd/thirp-broker.service
	deploy/systemd/thirp-web-ingress.service
)

FORBIDDEN_REL_PATTERNS=(
	'.cursor'
	'.cursor/'*
	'docs/inventions'
	'docs/inventions/'*
	'docs/STUDIO.md'
	'docs/MIGRATION.md'
	'docs/named-service-rendezvous-broker-spec-v3-acquisition.md'
	'docs/named-service-rendezvous-production-readiness-amendment.md'
	'docs/broker-packaging-change.md'
	'docs/rendez-authenticator-seam.md'
	'docs/rendez-authorizer-seam.md'
	'docs/rendez-sdk-distribution-spec.md'
	'docs/rendez-web-ingress-implementation-spec.md'
	'scripts/publish_github.sh'
	'scripts/public'
	'scripts/public/'*
)

rel_is_forbidden() {
	local rel="$1"
	local pat
	for pat in "${FORBIDDEN_REL_PATTERNS[@]}"; do
		# shellcheck disable=SC2254
		case "$rel" in
		$pat)
			return 0
			;;
		esac
	done
	return 1
}

check_public_archive() {
	local archive="$1"
	local member rel leak=0
	if [[ ! -f "$archive" ]]; then
		echo "stage_public_tree: archive missing: ${archive}" >&2
		exit 1
	fi
	while IFS= read -r member; do
		[[ -z "$member" ]] && continue
		rel="${member#*/}"
		rel="${rel%/}"
		if rel_is_forbidden "$rel"; then
			echo "stage_public_tree: private path in archive: ${rel}" >&2
			leak=1
		fi
	done < <(tar tzf "$archive")
	if [[ "$leak" -ne 0 ]]; then
		echo "stage_public_tree: archive is not a public tree" >&2
		exit 1
	fi
}

if [[ "${1:-}" == "--check-archive" ]]; then
	check_public_archive "${2:-}"
	exit 0
fi

STAGE="${1:-}"
if [[ -z "$STAGE" ]]; then
	echo "stage_public_tree: usage: $0 DEST | $0 --check-archive FILE.tar.gz" >&2
	exit 1
fi
mkdir -p "$STAGE"

copy_file() {
	local src="$1"
	local dest="${STAGE}/${src}"
	if [[ ! -f "${ROOT}/${src}" ]]; then
		echo "stage_public_tree: allowlist missing: ${src}" >&2
		exit 1
	fi
	mkdir -p "$(dirname "$dest")"
	cp -a "${ROOT}/${src}" "$dest"
}

copy_dir() {
	local src="$1"
	if [[ ! -d "${ROOT}/${src}" ]]; then
		echo "stage_public_tree: allowlist missing directory: ${src}" >&2
		exit 1
	fi
	mkdir -p "${STAGE}/${src}"
	cp -a "${ROOT}/${src}/." "${STAGE}/${src}/"
}

for pkg in "${ALLOW_PACKAGES[@]}"; do
	copy_dir "$pkg"
done
copy_dir examples

for f in "${ALLOW_ROOT_FILES[@]}" "${ALLOW_DOCS[@]}" "${ALLOW_SCRIPTS[@]}" "${ALLOW_DEPLOY[@]}"; do
	copy_file "$f"
done

mkdir -p "${STAGE}/.github"
if [[ -f "${ROOT}/scripts/public/github_SECURITY.md" ]]; then
	cp -a "${ROOT}/scripts/public/github_SECURITY.md" "${STAGE}/.github/SECURITY.md"
elif [[ -f "${ROOT}/.github/SECURITY.md" ]]; then
	cp -a "${ROOT}/.github/SECURITY.md" "${STAGE}/.github/SECURITY.md"
else
	echo "stage_public_tree: missing GitHub security policy" >&2
	exit 1
fi

if compgen -G "${STAGE}/deploy/systemd/rendez-*" > /dev/null; then
	echo "stage_public_tree: staged tree contains rendez systemd units" >&2
	exit 1
fi
if [[ -f "${STAGE}/c_abi/rendez.h" ]]; then
	echo "stage_public_tree: staged tree contains c_abi/rendez.h" >&2
	exit 1
fi

for pkgdir in "$ROOT"/*/; do
	if ! compgen -G "${pkgdir}"*.odin > /dev/null; then
		continue
	fi
	base="$(basename "$pkgdir")"
	listed=0
	for pkg in "${ALLOW_PACKAGES[@]}"; do
		if [[ "$pkg" == "$base" ]]; then
			listed=1
			break
		fi
	done
	if [[ "$listed" -eq 0 ]]; then
		echo "stage_public_tree: unlisted Odin package directory: ${base}" >&2
		echo "stage_public_tree: add it to ALLOW_PACKAGES if it is public source" >&2
		exit 1
	fi
done

for forbidden in \
	"${STAGE}/dist" \
	"${STAGE}/.cursor" \
	"${STAGE}/docs/inventions" \
	"${STAGE}/docs/STUDIO.md" \
	"${STAGE}/docs/MIGRATION.md" \
	"${STAGE}/docs/named-service-rendezvous-broker-spec-v3-acquisition.md" \
	"${STAGE}/docs/named-service-rendezvous-production-readiness-amendment.md" \
	"${STAGE}/docs/broker-packaging-change.md" \
	"${STAGE}/docs/rendez-authenticator-seam.md" \
	"${STAGE}/docs/rendez-authorizer-seam.md" \
	"${STAGE}/docs/rendez-sdk-distribution-spec.md" \
	"${STAGE}/docs/rendez-web-ingress-implementation-spec.md" \
	"${STAGE}/scripts/publish_github.sh" \
	"${STAGE}/scripts/public"
do
	if [[ -e "$forbidden" ]]; then
		echo "stage_public_tree: forbidden path staged: ${forbidden#"${STAGE}/"}" >&2
		exit 1
	fi
done

rewrite_md_links() {
	local file="$1"
	local dir
	dir="$(dirname "$file")"
	python3 - "$file" "$dir" "$STAGE" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
file_dir = pathlib.Path(sys.argv[2])
stage = pathlib.Path(sys.argv[3])
excluded = {
    "docs/MIGRATION.md",
    "MIGRATION.md",
    "docs/named-service-rendezvous-broker-spec-v3-acquisition.md",
    "docs/named-service-rendezvous-production-readiness-amendment.md",
    "docs/STUDIO.md",
    "docs/broker-packaging-change.md",
    "docs/rendez-authenticator-seam.md",
    "docs/rendez-authorizer-seam.md",
    "docs/rendez-sdk-distribution-spec.md",
    "docs/rendez-web-ingress-implementation-spec.md",
}
text = path.read_text(encoding="utf-8")
pat = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
errors = []

def rewrite(m):
    label, raw = m.group(1), m.group(2)
    target = raw.split("#", 1)[0]
    if not target or target.startswith(("http://", "https://", "mailto:", "irc:")):
        return m.group(0)
    if pathlib.Path(target).is_absolute():
        errors.append(f"absolute path link: {raw}")
        return m.group(0)
    resolved = (file_dir / target).resolve()
    try:
        rel = resolved.relative_to(stage.resolve())
    except ValueError:
        errors.append(f"link leaves staged tree: {raw}")
        return m.group(0)
    if resolved.exists():
        return m.group(0)
    rel_s = rel.as_posix()
    if target in excluded or rel_s in excluded:
        print(f"stage_public_tree: dropped private-only link {target} in {path.relative_to(stage)}", file=sys.stderr)
        return label
    name = pathlib.Path(target).name
    if name.startswith("rendez-") or name in {"rendez.h", "librendez.so"}:
        print(f"stage_public_tree: dropped former-name link {target} in {path.relative_to(stage)}", file=sys.stderr)
        return label
    errors.append(f"{path.relative_to(stage)}: missing {target}")
    return m.group(0)

new = pat.sub(rewrite, text)
if errors:
    for e in errors:
        print(f"stage_public_tree: {e}", file=sys.stderr)
    sys.exit(1)
if new != text:
    path.write_text(new, encoding="utf-8")
PY
}

while IFS= read -r -d '' md; do
	rewrite_md_links "$md"
done < <(find "$STAGE" -type f -name '*.md' -print0)

if [[ ! -f "${STAGE}/LICENSE" || ! -f "${STAGE}/NOTICE" ]]; then
	echo "stage_public_tree: staged tree missing LICENSE or NOTICE" >&2
	exit 1
fi
if ! grep -q 'Apache License' "${STAGE}/LICENSE"; then
	echo "stage_public_tree: staged LICENSE is not Apache-2.0" >&2
	exit 1
fi
if ! grep -q 'security@thirp.net' "${STAGE}/docs/SECURITY.md"; then
	echo "stage_public_tree: staged docs/SECURITY.md missing security@thirp.net" >&2
	exit 1
fi
if ! grep -q 'security@thirp.net' "${STAGE}/.github/SECURITY.md"; then
	echo "stage_public_tree: staged .github/SECURITY.md missing security@thirp.net" >&2
	exit 1
fi
