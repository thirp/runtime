#!/usr/bin/env bash
# Linux-hosted checks for the macOS/Windows data-plane release path.
# Does not compile .dylib/.dll (needs native runners).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

fail_msg() {
	echo "release_dataplane_test: $*" >&2
	fail=1
}

expect_file() {
	if [[ ! -f "$1" ]]; then
		fail_msg "missing $1"
	fi
}

for f in \
	scripts/release_common.sh \
	scripts/release_macos.sh \
	scripts/release_windows.ps1 \
	scripts/release_windows.bat \
	scripts/verify_dataplane_release.sh \
	scripts/build_macos.sh \
	scripts/build_windows.bat \
	scripts/ci_setup_odin.sh \
	scripts/ci_setup_odin.ps1 \
	.github/workflows/dataplane-release.yml
do
	expect_file "$f"
done

for f in scripts/release_common.sh scripts/release_macos.sh \
	scripts/verify_dataplane_release.sh scripts/build_macos.sh \
	scripts/ci_setup_odin.sh scripts/release_dataplane_test.sh \
	scripts/release.sh scripts/stage_public_tree.sh
do
	if ! bash -n "$f"; then
		fail_msg "bash -n failed: $f"
	fi
done

# shellcheck source=release_common.sh
source "${ROOT}/scripts/release_common.sh"
FP="$THIRP_PUBLISH_GPG_FINGERPRINT"
if [[ "$FP" != "3B8559D8754FB3C5B21110C786897A405CF3D8C4" ]]; then
	fail_msg "release_common.sh fingerprint drifted"
fi
if ! grep -q "$FP" "${ROOT}/docs/SECURITY.md"; then
	fail_msg "docs/SECURITY.md missing publish fingerprint"
fi
if ! grep -q "$FP" "${ROOT}/scripts/public/github_SECURITY.md"; then
	fail_msg "scripts/public/github_SECURITY.md missing publish fingerprint"
fi
if ! grep -q 'release_sign_sha256sums' "${ROOT}/scripts/release.sh"; then
	fail_msg "scripts/release.sh no longer uses release_sign_sha256sums"
fi
if ! grep -q "$FP" "${ROOT}/scripts/release_windows.ps1"; then
	fail_msg "scripts/release_windows.ps1 missing publish fingerprint"
fi

for needle in \
	scripts/release_common.sh \
	scripts/release_macos.sh \
	scripts/release_windows.ps1 \
	scripts/release_windows.bat \
	scripts/verify_dataplane_release.sh \
	scripts/build_macos.sh \
	scripts/build_windows.bat \
	scripts/ci_setup_odin.sh \
	scripts/ci_setup_odin.ps1 \
	scripts/release_dataplane_test.sh
do
	if ! grep -q "$needle" "${ROOT}/scripts/stage_public_tree.sh"; then
		fail_msg "stage_public_tree.sh allowlist missing ${needle}"
	fi
	if ! grep -q "$needle" "${ROOT}/scripts/publish_github.sh"; then
		fail_msg "publish_github.sh public-path list missing ${needle}"
	fi
done

if ! grep -q 'dataplane-release.yml' "${ROOT}/scripts/stage_public_tree.sh"; then
	fail_msg "stage_public_tree.sh does not publish the GitHub Actions workflow"
fi
if ! grep -q 'macos-latest' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing macos-latest"
fi
if ! grep -q 'windows-latest' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing windows-latest"
fi
if ! grep -q 'release_macos.sh' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not invoke release_macos.sh"
fi
if ! grep -q 'release_windows.ps1' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not invoke release_windows.ps1"
fi

if grep -q 'release packaging for macOS and Windows is not yet automated' "${ROOT}/README.md"; then
	fail_msg "README still says macOS/Windows release packaging is not automated"
fi
if ! grep -q 'release_macos.sh' "${ROOT}/docs/BUILDING.md"; then
	fail_msg "BUILDING.md missing release_macos.sh"
fi
if ! grep -q 'THIRP_MACOS_CODESIGN_IDENTITY' "${ROOT}/docs/BUILDING.md"; then
	fail_msg "BUILDING.md missing Apple Developer ID blocker name"
fi
if ! grep -q 'THIRP_WINDOWS_PFX' "${ROOT}/docs/BUILDING.md"; then
	fail_msg "BUILDING.md missing Authenticode blocker name"
fi

# Fixture: darwin tree verifies; broker binary is rejected.
FIX="${ROOT}/dist/dataplane-release-test"
rm -rf "$FIX"
mkdir -p "${FIX}/darwin" "${FIX}/windows" "${FIX}/bad"

write_sums() {
	local dir="$1"
	shift
	(
		cd "$dir"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$@" > SHA256SUMS
		else
			shasum -a 256 "$@" > SHA256SUMS
		fi
	)
}

for name in thirp-agent thirp-connect libthirp.dylib thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md; do
	printf 'darwin-%s\n' "$name" > "${FIX}/darwin/${name}"
done
cat > "${FIX}/darwin/PROVENANCE.txt" <<'EOF'
name: thirp-runtime
version: 0.16.3
source_commit: deadbeef
target: darwin arm64
artifact_kind: dataplane
components: thirp-agent thirp-connect libthirp
build_command: scripts/release_macos.sh
EOF
write_sums "${FIX}/darwin" thirp-agent thirp-connect libthirp.dylib thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md PROVENANCE.txt
if ! bash "${ROOT}/scripts/verify_dataplane_release.sh" "${FIX}/darwin" darwin; then
	fail_msg "verify_dataplane_release.sh rejected a valid darwin fixture"
fi

for name in thirp-agent.exe thirp-connect.exe libthirp.dll thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md; do
	printf 'windows-%s\n' "$name" > "${FIX}/windows/${name}"
done
cat > "${FIX}/windows/PROVENANCE.txt" <<'EOF'
name: thirp-runtime
version: 0.16.3
source_commit: deadbeef
target: windows AMD64
artifact_kind: dataplane
components: thirp-agent thirp-connect libthirp
build_command: scripts/release_windows.ps1
EOF
write_sums "${FIX}/windows" thirp-agent.exe thirp-connect.exe libthirp.dll thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md PROVENANCE.txt
if ! bash "${ROOT}/scripts/verify_dataplane_release.sh" "${FIX}/windows" windows; then
	fail_msg "verify_dataplane_release.sh rejected a valid windows fixture"
fi

cp -a "${FIX}/darwin/." "${FIX}/bad/"
printf 'nope\n' > "${FIX}/bad/thirp-broker"
if bash "${ROOT}/scripts/verify_dataplane_release.sh" "${FIX}/bad" darwin >/dev/null 2>&1; then
	fail_msg "verify_dataplane_release.sh accepted a tree that contains thirp-broker"
fi

rm -rf "$FIX"

if [[ "$fail" -ne 0 ]]; then
	echo "release_dataplane_test: FAIL" >&2
	exit 1
fi
echo "release_dataplane_test: ok"
