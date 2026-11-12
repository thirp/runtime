#!/usr/bin/env bash
# Owen runs as clay on each Mac; no sudo, SSH, launchd or prefix manipulation.
# M4: OPENSSL_PREFIX=/opt/homebrew/opt/openssl@3
#     PATH=/Users/clay/opt/odin-dev-2026-07a:$PATH (819fdc7)
# iMac: OPENSSL_PREFIX=/opt/local/libexec/openssl3
#       set ODIN or PATH to Clay's existing compiler (not on default PATH).
# If copied to /Users/clay/work/, set THIRP_SOURCE to this branch's checkout.
# Optional REPLAY_WORKTREE must name a NEW directory. Logs/artifacts stay there.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'replay: Darwin only' >&2; exit 1; }
[[ $(id -u) != 0 ]] || { echo 'replay: run as clay, not root' >&2; exit 1; }
: "${OPENSSL_PREFIX:?set OPENSSL_PREFIX to the lab OpenSSL 3 prefix}"
ODIN="${ODIN:-odin}"
ODIN="$(command -v "$ODIN")" || { echo 'replay: set ODIN or PATH to Clay’s existing Odin; nothing will be installed' >&2; exit 1; }
ODIN="$(cd "$(dirname "$ODIN")" && pwd)/$(basename "$ODIN")"
export ODIN
SOURCE="${THIRP_SOURCE:-$(cd "$(dirname "$0")/.." && pwd)}"
[[ -f "$SOURCE/scripts/macos_openssl.sh" ]] || { echo 'replay: set THIRP_SOURCE to the static-OpenSSL branch checkout' >&2; exit 1; }
if [[ -n ${REPLAY_WORKTREE:-} ]]; then
	WORK="$REPLAY_WORKTREE"
	[[ "$WORK" == /* && ! -e "$WORK" ]] || { echo 'replay: REPLAY_WORKTREE must be an absolute path that does not exist' >&2; exit 1; }
else
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/thirp-macos-static.XXXXXX")"
	rmdir "$WORK"
fi
git -C "$SOURCE" worktree add --detach "$WORK" HEAD
cd "$WORK"
WORK="$PWD"
mkdir -p "$WORK/evidence" "$WORK/replay-tools"
exec > >(tee "$WORK/evidence/replay.log") 2>&1
# release_common.sh locates `odin`; honor ODIN even if it has another name.
cat > "$WORK/replay-tools/odin" <<'WRAPPER'
#!/usr/bin/env bash
exec "$ODIN" "$@"
WRAPPER
chmod +x "$WORK/replay-tools/odin"
export PATH="$WORK/replay-tools:$PATH"
echo "replay: worktree=$WORK commit=$(git rev-parse HEAD) arch=$(uname -m) prefix=$OPENSSL_PREFIX"
"$ODIN" version
# This replay uses ad-hoc hardened signing below; Clay's release signing is separate.
unset THIRP_MACOS_CODESIGN_IDENTITY THIRP_MACOS_NOTARY_PROFILE
bash scripts/release_macos.sh
VERSION="$(tr -d '[:space:]' < VERSION.txt)"
OUT="$WORK/dist/thirp-runtime-macos-$(uname -m)-$VERSION"
ARCHIVE="$OUT.tar.gz"
# Preserve the release archive and validate its unpacked contents.
mkdir "$WORK/evidence/unpacked"
tar -xzf "$ARCHIVE" -C "$WORK/evidence/unpacked"
bash scripts/verify_dataplane_release.sh "$WORK/evidence/unpacked/$(basename "$OUT")" darwin | tee "$WORK/evidence/archive-guard.log"
# Run copied binaries from a separate directory; never hide/rename an OpenSSL
# prefix. M4 pid 1612 uses it. No live agent tree or process is touched.
# Security.framework pulls Apple's own /usr/lib/libssl.NN / libcrypto.NN
# (LibreSSL) from the shared cache. Those are platform images, not ours;
# anything else named libssl/libcrypto, or any package-manager path, fails.
forbidden_images() {
	grep -iE 'libssl|libcrypto|/opt/homebrew|/opt/local/|Cellar' "$1" |
		grep -vE '(^|[[:space:]])/usr/lib/lib(ssl|crypto)\.[0-9]+\.dylib$'
}

RUN="$WORK/evidence/hardened"
mkdir "$RUN"
for bin in thirp-agent thirp-connect libthirp.dylib; do
	cp "$OUT/$bin" "$RUN/$bin"
	codesign --force -o runtime -s - "$RUN/$bin"
	codesign --verify --verbose "$RUN/$bin"
	codesign -dv --verbose=4 "$RUN/$bin" 2>&1 | tee "$WORK/evidence/$bin-signing.log"
	grep -q 'flags=.*runtime' "$WORK/evidence/$bin-signing.log"
done
bash scripts/verify_macho_dependencies.sh "$RUN" | tee "$WORK/evidence/otool-guard.log"
for bin in thirp-agent thirp-connect; do
	"$RUN/$bin" --version | tee "$WORK/evidence/$bin-version-hardened.log"
	# Hardened runtime strips DYLD_* variables, so log loads from the same
	# build before signing; the hardened copy is checked live with lsof below.
	DYLD_PRINT_LIBRARIES=1 "$OUT/$bin" --version > "$WORK/evidence/$bin-version-dyld.log" 2>&1
	cat "$WORK/evidence/$bin-version-dyld.log"
	# Require positive dyld logging evidence, not just absence of forbidden names.
	grep -qE 'dyld.*(/usr/lib/|/System/Library/)' "$WORK/evidence/$bin-version-dyld.log"
	if forbidden_images "$WORK/evidence/$bin-version-dyld.log" ||
		grep -F "$OPENSSL_PREFIX/" "$WORK/evidence/$bin-version-dyld.log"; then
		echo 'replay: forbidden runtime OpenSSL load' >&2; exit 1
	fi
done
# Build a native throwaway broker (MODE=all also verifies broker/web ingress).
bash scripts/build_macos.sh all
BROKER_PID=''; AGENT_PID=''
cleanup() {
	if [[ -n "$AGENT_PID" ]]; then kill "$AGENT_PID" 2>/dev/null || true; wait "$AGENT_PID" 2>/dev/null || true; fi
	if [[ -n "$BROKER_PID" ]]; then kill "$BROKER_PID" 2>/dev/null || true; wait "$BROKER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
"$OPENSSL_PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
	-keyout "$WORK/evidence/broker.key" -out "$WORK/evidence/broker.crt" \
	-subj /CN=localhost -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' > "$WORK/evidence/cert.log" 2>&1
# The kernel chooses an unused loopback port. No fixed lab/soak listener ports.
printf '%s\n' 'replay-throwaway-token=replay-agent' > "$WORK/evidence/broker.tokens"
printf '%s\n' 'replay-throwaway-token' > "$WORK/evidence/agent.token"
chmod 600 "$WORK/evidence/"*.key "$WORK/evidence/"*.token "$WORK/evidence/"*.tokens
"$OUT/thirp-broker" --listen 127.0.0.1:0 --tls-cert "$WORK/evidence/broker.crt" \
	--tls-key "$WORK/evidence/broker.key" --token-file "$WORK/evidence/broker.tokens" \
	--shutdown-grace 0 > "$WORK/evidence/broker.log" 2>&1 &
BROKER_PID=$!
endpoint=''
for ((i=0;i<100;i++)); do
	endpoint="$(sed -n 's/^thirp-broker listening on \(127\.0\.0\.1:[0-9]*\).*$/\1/p' "$WORK/evidence/broker.log" | head -1)"
	[[ -n "$endpoint" ]] && break
	kill -0 "$BROKER_PID" 2>/dev/null || { cat "$WORK/evidence/broker.log"; exit 1; }
	sleep 0.1
done
[[ -n "$endpoint" ]] || { echo 'replay: throwaway broker did not report its ephemeral port' >&2; exit 1; }
"$RUN/thirp-agent" --broker "$endpoint" --tls-ca "$WORK/evidence/broker.crt" \
	--token-file "$WORK/evidence/agent.token" --service replay/static-openssl --target 127.0.0.1:1 \
	> "$WORK/evidence/register.log" 2>&1 &
AGENT_PID=$!
registered=0
for ((i=0;i<100;i++)); do
	if grep -q 'registered replay/static-openssl' "$WORK/evidence/register.log"; then registered=1; break; fi
	kill -0 "$AGENT_PID" 2>/dev/null || break
	sleep 0.1
done
cat "$WORK/evidence/register.log"
[[ $registered == 1 ]] || { echo 'replay: local registration failed' >&2; exit 1; }
# Images mapped by the live hardened-runtime agent, including after TLS setup.
lsof -p "$AGENT_PID" -Fn | sed -n 's/^n//p' > "$WORK/evidence/agent-hardened-lsof.log"
cat "$WORK/evidence/agent-hardened-lsof.log"
grep -qF "$RUN/thirp-agent" "$WORK/evidence/agent-hardened-lsof.log"
if forbidden_images "$WORK/evidence/agent-hardened-lsof.log"; then
	echo 'replay: hardened agent mapped a forbidden OpenSSL image' >&2; exit 1
fi
cleanup; AGENT_PID=''; BROKER_PID=''
# Exactly the same archive staging/private flags as all Darwin product builds.
source scripts/macos_openssl.sh
macos_prepare_openssl
"$ODIN" test . -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
	-define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS" \
	> "$WORK/evidence/odin-test.log" 2>&1
cat "$WORK/evidence/odin-test.log"
if grep -q '+++ leak' "$WORK/evidence/odin-test.log"; then echo 'replay: test leak' >&2; exit 1; fi
echo "replay: PASS arch=$(uname -m): archive guard, otool, ad-hoc runtime versions/dyld, local TLS registration, full Odin suite exit=0"
echo "replay: original release archive=$ARCHIVE; evidence=$WORK/evidence"
