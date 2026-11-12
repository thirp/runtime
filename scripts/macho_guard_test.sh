#!/usr/bin/env bash
# Generated load-command fixtures; runnable with Bash 3.2 on Linux or Darwin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="${1:?usage: macho_guard_test.sh FIXTURE_DIR}"
mkdir -p "$FIX"
# Emit a little-endian uint32 without passing NULs through shell variables.
u32() {
	local n="$1" i oct
	for ((i=0;i<4;i++)); do
		printf -v oct '\\%03o' "$((n & 255))"
		printf '%b' "$oct"
		n=$((n >> 8))
	done
}
thin() {
	local path="$1" cmd="${2:-12}" cpu="${3:-16777228}" len i
	len=$(( (24+${#path}+1+7)/8*8 ))
	printf '\317\372\355\376'
	u32 "$cpu"; u32 0; u32 2; u32 1; u32 "$len"; u32 0; u32 0
	u32 "$cmd"; u32 "$len"; u32 24; u32 0; u32 0; u32 0
	printf '%s' "$path"
	for ((i=24+${#path};i<len;i++)); do printf '\0'; done
}
# Seed existing full release fixtures with real Mach-O headers/load commands.
for name in thirp-agent thirp-connect libthirp.dylib; do
	thin /usr/lib/libSystem.B.dylib > "$FIX/$name"
done
if [[ ${2:-} == seed ]]; then exit 0; fi
GUARD="$ROOT/scripts/verify_macho_dependencies.sh"
expect() {
	local want="$1" label="$2" got=0
	bash "$GUARD" "$FIX" > "$FIX/guard.log" 2>&1 || got=$?
	if [[ $want == pass && $got != 0 || $want == fail && $got == 0 ]]; then
		cat "$FIX/guard.log"; echo "macho_guard_test: unexpected $label ($got)" >&2; exit 1
	fi
	echo "macho_guard_test: $want $label"
}
expect pass 'system arm64 dependencies'
thin /System/Library/Frameworks/Security.framework/Versions/A/Security 12 16777223 > "$FIX/thirp-connect"
expect pass 'system framework x86_64 dependency'
for path in /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib \
	/opt/local/libexec/openssl3/lib/libcrypto.3.dylib \
	/opt/local/lib/libz.dylib /usr/local/opt/openssl/lib/libssl.3.dylib \
	/usr/lib/libssl.3.dylib @rpath/libcrypto.3.dylib \
	/usr/lib/../../opt/evil.dylib @rpath/absent.dylib; do
	thin "$path" > "$FIX/thirp-agent"
	expect fail "$path"
done
# Check every dependency command family, including high-bit LC_REQ_DYLD.
for cmd in 12 2147483672 2147483679 32 2147483683; do
	thin /third-party/evil.dylib "$cmd" > "$FIX/thirp-agent"
	expect fail "load command $cmd"
done
printf 'shipped\n' > "$FIX/local.dylib"
for path in @rpath/local.dylib @loader_path/local.dylib @executable_path/local.dylib; do
	thin "$path" > "$FIX/thirp-agent"; expect pass "$path"
done
thin /usr/lib/libSystem.B.dylib > "$FIX/thirp-agent"
# A fat container with clean first slice, forbidden second slice. Fat headers BE.
thin /opt/local/lib/libz.dylib 12 16777223 > "$FIX/slice"
size1=$(wc -c < "$FIX/thirp-agent"); size2=$(wc -c < "$FIX/slice")
be32() { local n="$1" i oct; for ((i=3;i>=0;i--)); do printf -v oct '\\%03o' "$(((n >> (i*8)) & 255))"; printf '%b' "$oct"; done; }
fat() {
	printf '\312\376\272\276'; be32 2
	be32 16777228; be32 0; be32 48; be32 "$size1"; be32 0
	be32 16777223; be32 0; be32 "$((48+size1))"; be32 "$size2"; be32 0
	cat "$FIX/thirp-agent" "$FIX/slice"
}
fat > "$FIX/universal"
mv "$FIX/universal" "$FIX/thirp-connect"
expect fail 'forbidden second fat slice'
thin /usr/lib/libSystem.B.dylib 12 16777223 > "$FIX/slice"
size2=$(wc -c < "$FIX/slice")
fat > "$FIX/universal"; mv "$FIX/universal" "$FIX/thirp-connect"
expect pass 'both fat slices clean'
# Fat64 table and swapped fat byte order also cover every slice.
fat64() {
	printf '\312\376\272\277'; be32 2
	be32 16777228; be32 0; be32 0; be32 72; be32 0; be32 "$size1"; be32 0; be32 0
	be32 16777223; be32 0; be32 0; be32 "$((72+size1))"; be32 0; be32 "$size2"; be32 0; be32 0
	cat "$FIX/thirp-agent" "$FIX/slice"
}
fat64 > "$FIX/universal"; mv "$FIX/universal" "$FIX/thirp-connect"
expect pass 'fat64 clean slices'
thin /opt/local/lib/libz.dylib 12 16777223 > "$FIX/slice"
size2=$(wc -c < "$FIX/slice")
fat64 > "$FIX/universal"; mv "$FIX/universal" "$FIX/thirp-connect"
expect fail 'forbidden second fat64 slice'
# CIGAM fat table in little endian.
fat_swapped() {
	printf '\276\272\376\312'; u32 2
	u32 16777228; u32 0; u32 48; u32 "$size1"; u32 0
	u32 16777223; u32 0; u32 "$((48+size1))"; u32 "$size2"; u32 0
	cat "$FIX/thirp-agent" "$FIX/slice"
}
fat_swapped > "$FIX/universal"; mv "$FIX/universal" "$FIX/thirp-connect"
expect fail 'forbidden second swapped fat slice'
rm "$FIX/slice"
thin /usr/lib/libSystem.B.dylib 12 16777223 > "$FIX/thirp-connect"
# Big-endian thin 64-bit Mach-O header and dylib command.
path=/usr/lib/libSystem.B.dylib
length=$(( (24+${#path}+1+7)/8*8 ))
{
	printf '\376\355\372\317'
	be32 16777223; be32 0; be32 2; be32 1; be32 "$length"; be32 0; be32 0
	be32 12; be32 "$length"; be32 24; be32 0; be32 0; be32 0
	printf '%s' "$path"
	for ((i=24+${#path};i<length;i++)); do printf '\0'; done
} > "$FIX/thirp-connect"
expect pass 'big endian thin load commands'

# Additional Mach-O files anywhere in the tree must also be inspected.
mkdir -p "$FIX/nested"
thin /opt/local/lib/libz.dylib > "$FIX/nested/extra"
expect fail 'extra nested Mach-O'
rm "$FIX/nested/extra"
printf '\317\372\355\376' > "$FIX/thirp-agent"
expect fail 'truncated Mach-O'
printf 'not Mach-O\n' > "$FIX/thirp-agent"
expect fail 'required binary is text'
echo 'macho_guard_test: ok'
