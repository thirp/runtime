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
	scripts/release.sh scripts/release_sdk.sh scripts/assemble_sdk.sh \
	scripts/stage_public_tree.sh
do
	if ! bash -n "$f"; then
		fail_msg "bash -n failed: $f"
	fi
done

# shellcheck source=release_common.sh
source "${ROOT}/scripts/release_common.sh"
VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION.txt")"
release_require_project_version "$VERSION"
FP="$THIRP_PUBLISH_GPG_FINGERPRINT"
if [[ "$FP" != "3B8559D8754FB3C5B21110C786897A405CF3D8C4" ]]; then
	fail_msg "release_common.sh fingerprint drifted"
fi
if ! grep -q "$FP" "${ROOT}/docs/SECURITY.md"; then
	fail_msg "docs/SECURITY.md missing publish fingerprint"
fi
# Origin: scripts/public/github_SECURITY.md. Public squash: .github/SECURITY.md.
if [[ -f "${ROOT}/scripts/public/github_SECURITY.md" ]]; then
	if ! grep -q "$FP" "${ROOT}/scripts/public/github_SECURITY.md"; then
		fail_msg "scripts/public/github_SECURITY.md missing publish fingerprint"
	fi
elif [[ -f "${ROOT}/.github/SECURITY.md" ]]; then
	if ! grep -q "$FP" "${ROOT}/.github/SECURITY.md"; then
		fail_msg ".github/SECURITY.md missing publish fingerprint"
	fi
else
	fail_msg "no GitHub SECURITY.md with publish fingerprint"
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
	scripts/assemble_sdk.sh \
	scripts/release_dataplane_test.sh
do
	if ! grep -q "$needle" "${ROOT}/scripts/stage_public_tree.sh"; then
		fail_msg "stage_public_tree.sh allowlist missing ${needle}"
	fi
	if [[ -f "${ROOT}/scripts/publish_github.sh" ]]; then
		if ! grep -q "$needle" "${ROOT}/scripts/publish_github.sh"; then
			fail_msg "publish_github.sh public-path list missing ${needle}"
		fi
	fi
done

if ! grep -q 'dataplane-release.yml' "${ROOT}/scripts/stage_public_tree.sh"; then
	fail_msg "stage_public_tree.sh does not publish the GitHub Actions workflow"
fi
if ! grep -q 'macos-latest' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing macos-latest"
fi
if ! grep -q 'macos-15-intel' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing macos-15-intel"
fi
if ! grep -q 'arch: x86_64' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing macos x86_64 (Intel) matrix arch"
fi
if ! grep -q 'arch: arm64' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow missing macos arm64 matrix arch"
fi
if ! grep -q 'thirp-runtime-macos-${{ matrix.arch }}' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow macos artifact name is not arch-specific"
fi
if grep -q 'if: \${{ secrets\.' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow uses secrets in if: (GitHub rejects Unrecognized named-value: secrets)"
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
if ! grep -q 'assemble_sdk.sh' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not assemble the multi-OS SDK"
fi
if ! grep -q 'odin build c_abi -build-mode:shared -out:dist/libthirp.so' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not build Linux libthirp.so for the SDK"
fi
if ! grep -q 'C:\\Program Files\\OpenSSL"' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not search C:\\Program Files\\OpenSSL"
fi
if ! grep -q 'system:libssl.lib' "${ROOT}/transport/openssl.odin"; then
	fail_msg "openssl.odin Windows import missing system:libssl.lib"
fi
if ! grep -q 'system:crypt32.lib' "${ROOT}/transport/tls_verify_windows.odin"; then
	fail_msg "tls_verify_windows.odin missing local crypt32 FFI for Odin 2026-07"
fi
if grep -E '\$existing = & gpg --list-secret-keys' "${ROOT}/scripts/release_windows.ps1"; then
	fail_msg "release_windows.ps1 GPG probe uses native stderr under ErrorAction Stop"
fi
if ! grep -q 'cmd /c "gpg --list-secret-keys' "${ROOT}/scripts/release_windows.ps1"; then
	fail_msg "release_windows.ps1 GPG probe must go through cmd /c so first-run stderr is not fatal"
fi
if ! grep -q 'OPENSSL_LIBPATH' "${ROOT}/scripts/build_windows.bat"; then
	fail_msg "build_windows.bat does not locate OPENSSL_LIBPATH"
fi
if ! grep -q 'set "LIB=%OPENSSL_LIBPATH%;%LIB%"' "${ROOT}/scripts/build_windows.bat"; then
	fail_msg "build_windows.bat does not prepend OPENSSL_LIBPATH to LIB"
fi
if grep -q 'use all or dataplane)' "${ROOT}/scripts/build_windows.bat"; then
	fail_msg "build_windows.bat unknown-mode echo still has cmd.exe-breaking parentheses"
fi
if ! grep -q 'vswhere' "${ROOT}/.github/workflows/dataplane-release.yml"; then
	fail_msg "workflow does not locate MSVC via vswhere"
fi
if [[ -f "${ROOT}/transport/entry_darwin.odin" ]]; then
	fail_msg "transport/entry_darwin.odin is a 2026-09-only stub; CI is pinned to 2026-07"
fi
if ! grep -q 'ODIN_TAG="${ODIN_TAG:-dev-2026-07}"' "${ROOT}/scripts/ci_setup_odin.sh"; then
	fail_msg "ci_setup_odin.sh default tag is not dev-2026-07"
fi
if ! grep -q '"dev-2026-07"' "${ROOT}/scripts/ci_setup_odin.ps1"; then
	fail_msg "ci_setup_odin.ps1 default tag is not dev-2026-07"
fi
if ! grep -q 'odin-macos-${ODIN_ARCH}-${ODIN_TAG}.tar.gz' "${ROOT}/scripts/ci_setup_odin.sh"; then
	fail_msg "ci_setup_odin.sh missing macos tar.gz candidate"
fi
if ! grep -q 'gzip -t' "${ROOT}/scripts/ci_setup_odin.sh"; then
	fail_msg "ci_setup_odin.sh does not sniff gzip archives"
fi

if grep -q 'release packaging for macOS and Windows is not yet automated' "${ROOT}/README.md"; then
	fail_msg "README still says macOS/Windows release packaging is not automated"
fi
if grep -qE 'amd64 \(Intel\) is not published yet|macOS Intel is not published yet' \
	"${ROOT}/README.md" "${ROOT}/docs/BUILDING.md" \
	"${ROOT}/docs/COMPATIBILITY.md" "${ROOT}/docs/QUICKSTART.md"; then
	fail_msg "docs still say macOS Intel is not published yet"
fi
if ! grep -q 'macos-15-intel' "${ROOT}/docs/BUILDING.md"; then
	fail_msg "BUILDING.md missing macos-15-intel"
fi
if ! grep -q 'v0.16.4' "${ROOT}/docs/QUICKSTART.md"; then
	fail_msg "QUICKSTART.md missing v0.16.4"
fi
if ! grep -q 'v0.16.4' "${ROOT}/README.md"; then
	fail_msg "README.md missing v0.16.4"
fi
if ! grep -q 'dev-2026-07' "${ROOT}/docs/CHANGELOG.md"; then
	fail_msg "CHANGELOG.md missing the dev-2026-07 Odin pin note"
fi
for doc in README.md docs/QUICKSTART.md docs/BUILDING.md docs/COMPATIBILITY.md docs/SDK.md docs/SECURITY.md docs/OPERATIONS.md; do
	if grep -q 'v0.16.3-dataplane-unsigned' "${ROOT}/${doc}"; then
		fail_msg "${doc} still points at a split v0.16.3 dataplane tag"
	fi
done
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

mkdir -p "${FIX}/darwin-intel"
cp -a "${FIX}/darwin/." "${FIX}/darwin-intel/"
cat > "${FIX}/darwin-intel/PROVENANCE.txt" <<'EOF'
name: thirp-runtime
version: 0.16.3
source_commit: deadbeef
target: darwin x86_64
artifact_kind: dataplane
components: thirp-agent thirp-connect libthirp
build_command: scripts/release_macos.sh
EOF
write_sums "${FIX}/darwin-intel" thirp-agent thirp-connect libthirp.dylib thirp.h LICENSE NOTICE CHANGELOG.md DEPENDENCIES.md PROVENANCE.txt
if ! bash "${ROOT}/scripts/verify_dataplane_release.sh" "${FIX}/darwin-intel" darwin; then
	fail_msg "verify_dataplane_release.sh rejected a valid darwin x86_64 fixture"
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

# Fixture: four dummy libraries become one SDK tarball.
SDK_FIX="${FIX}/sdk-ci"
rm -rf "$SDK_FIX"
mkdir -p "$SDK_FIX"
printf 'linux-so\n' > "${SDK_FIX}/libthirp.so"
for arch in arm64 x86_64; do
	tree="$(mktemp -d)"
	printf 'dylib-%s\n' "$arch" > "${tree}/libthirp.dylib"
	tar -C "$tree" -czf "${SDK_FIX}/thirp-runtime-macos-${arch}-test.tar.gz" libthirp.dylib
	rm -rf "$tree"
done
python3 - "${SDK_FIX}/thirp-runtime-windows-AMD64-test.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("thirp-runtime-windows-test/libthirp.dll", b"dll\n")
PY
if ! bash "${ROOT}/scripts/assemble_sdk.sh" "$SDK_FIX"; then
	fail_msg "assemble_sdk.sh rejected a complete four-library fixture"
else
	ver="$(tr -d '[:space:]' < "${ROOT}/VERSION.txt")"
	sdk_tar="${SDK_FIX}/thirp-runtime-sdk-${ver}.tar.gz"
	manifest="$(tar -xOzf "$sdk_tar" "thirp-runtime-sdk-${ver}/SDK_MANIFEST.json")"
	for needle in \
		'"target": "linux-x86_64"' \
		'"target": "darwin-arm64"' \
		'"target": "darwin-x86_64"' \
		'"target": "windows-amd64"' \
		"c/lib/linux-x86_64/libthirp.so" \
		"c/lib/darwin-arm64/libthirp.dylib" \
		"c/lib/darwin-x86_64/libthirp.dylib" \
		"c/lib/windows-amd64/libthirp.dll"
	do
		if ! grep -q -F "$needle" <<<"$manifest"; then
			fail_msg "SDK manifest missing ${needle}"
		fi
	done
fi

SHORT="${FIX}/sdk-short"
rm -rf "$SHORT"
mkdir -p "$SHORT"
cp "${SDK_FIX}/libthirp.so" "$SHORT/"
cp "${SDK_FIX}/thirp-runtime-macos-arm64-test.tar.gz" "$SHORT/"
cp "${SDK_FIX}/thirp-runtime-macos-x86_64-test.tar.gz" "$SHORT/"
if bash "${ROOT}/scripts/assemble_sdk.sh" "$SHORT" >/dev/null 2>&1; then
	fail_msg "assemble_sdk.sh accepted a fixture with no Windows library"
fi

rm -rf "$FIX"

if [[ "$fail" -ne 0 ]]; then
	echo "release_dataplane_test: FAIL" >&2
	exit 1
fi
echo "release_dataplane_test: ok"
