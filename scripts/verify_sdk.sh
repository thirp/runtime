#!/usr/bin/env bash
# Clean-room SDK verification and Host/Caller smoke against a release Broker.
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

SDK_TAR="${OUT}/thirp-runtime-sdk-${VERSION}.tar.gz"
BROKER="${OUT}/thirp-broker"
C_TARGET="linux-${ARCH}"

if [[ ! -f "$SDK_TAR" ]]; then
	echo "verify_sdk: missing ${SDK_TAR}" >&2
	exit 1
fi
if [[ ! -x "$BROKER" ]]; then
	echo "verify_sdk: missing ${BROKER}" >&2
	exit 1
fi

EXTRACT="$(mktemp -d /tmp/thirp-runtime-sdk-verify.XXXXXX)"
cleanup() {
	if [[ -n "${HOST_PID:-}" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
		kill -TERM "$HOST_PID" 2>/dev/null || true
		wait "$HOST_PID" 2>/dev/null || true
	fi
	if [[ -n "${BROKER_PID:-}" ]] && kill -0 "$BROKER_PID" 2>/dev/null; then
		kill -TERM "$BROKER_PID" 2>/dev/null || true
		wait "$BROKER_PID" 2>/dev/null || true
	fi
	rm -rf "$EXTRACT"
}
trap cleanup EXIT

tar -xzf "$SDK_TAR" -C "$EXTRACT"
SDK_ROOT="${EXTRACT}/thirp-runtime-sdk-${VERSION}"
if [[ ! -d "$SDK_ROOT" ]]; then
	echo "verify_sdk: tarball missing ${SDK_NAME:-thirp-runtime-sdk-${VERSION}}/" >&2
	exit 1
fi

echo "verify_sdk: extracted ${SDK_ROOT}"

(
	cd "$SDK_ROOT"
	sha256sum -c SHA256SUMS
)

python3 - "$SDK_ROOT" <<'PY'
import hashlib, json, os, sys

root = sys.argv[1]
with open(os.path.join(root, "SDK_MANIFEST.json"), encoding="utf-8") as f:
    manifest = json.load(f)

required = [
    "manifest_version",
    "project",
    "project_version",
    "protocol_version",
    "odin_min_version",
    "odin_collection_root",
    "public_packages",
    "c_abi",
    "files",
]
for key in required:
    if key not in manifest:
        raise SystemExit(f"verify_sdk: manifest missing {key}")

if manifest["project"] != "thirp-runtime":
    raise SystemExit("verify_sdk: project is not thirp-runtime")
if manifest["protocol_version"] != "1.0":
    raise SystemExit("verify_sdk: protocol_version is not 1.0")
if manifest["odin_collection_root"] != "odin/thirp":
    raise SystemExit("verify_sdk: odin_collection_root mismatch")
if manifest["public_packages"] != ["agent", "caller"]:
    raise SystemExit("verify_sdk: public_packages mismatch")

declared = {}
for entry in manifest["files"]:
    path = entry["path"]
    declared[path] = entry
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        raise SystemExit(f"verify_sdk: manifest path missing: {path}")
    size = os.path.getsize(full)
    if size != entry["size"]:
        raise SystemExit(f"verify_sdk: size mismatch for {path}")
    h = hashlib.sha256()
    with open(full, "rb") as f:
        h.update(f.read())
    if h.hexdigest() != entry["sha256"]:
        raise SystemExit(f"verify_sdk: sha256 mismatch for {path}")

skip = {"SDK_MANIFEST.json", "SHA256SUMS"}
actual = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        rel = os.path.relpath(os.path.join(dirpath, name), root)
        if rel not in skip:
            actual.append(rel.replace("\\", "/"))
extra = sorted(set(actual) - set(declared))
missing = sorted(set(declared) - set(actual))
if extra:
    raise SystemExit("verify_sdk: undeclared files: " + ", ".join(extra))
if missing:
    raise SystemExit("verify_sdk: declared files missing: " + ", ".join(missing))

for needle in ("LICENSE", "NOTICE", "VERSION.txt", "docs/PROTOCOL.md", "docs/SDK.md", "docs/COMPATIBILITY.md"):
    if not os.path.isfile(os.path.join(root, needle)):
        raise SystemExit(f"verify_sdk: missing {needle}")

with open(os.path.join(root, "VERSION.txt"), encoding="utf-8") as f:
    version = f.read().strip()
if version != manifest["project_version"]:
    raise SystemExit("verify_sdk: VERSION.txt does not match project_version")

forbidden_dirs = [
    "odin/thirp/broker",
    "odin/thirp/auth",
    "odin/thirp/config",
    "odin/thirp/c_abi",
    "odin/thirp/version",
    "odin/thirp/web_ingress",
    "odin/thirp/agent_cli",
    "odin/thirp/caller_cli",
    "odin/thirp/broker_cli",
]
for d in forbidden_dirs:
    if os.path.isdir(os.path.join(root, d)):
        raise SystemExit(f"verify_sdk: forbidden directory present: {d}")

for dirpath, _, filenames in os.walk(os.path.join(root, "odin")):
    for name in filenames:
        if name.endswith("_test.odin") or name == "test_helpers.odin":
            raise SystemExit(f"verify_sdk: test file present: {os.path.join(dirpath, name)}")
        if name.endswith(".git"):
            raise SystemExit("verify_sdk: git metadata present")

print("verify_sdk: manifest ok")
PY

COLLECTION="${SDK_ROOT}/odin/thirp"
HOST_SRC="${SDK_ROOT}/examples/odin/ephemeral_host"
CALLER_SRC="${SDK_ROOT}/examples/odin/join_code_client"
C_SRC="${SDK_ROOT}/examples/c/echo_client/echo_client.c"
HOST_BIN="${EXTRACT}/ephemeral_host"
CALLER_BIN="${EXTRACT}/join_code_client"
C_BIN="${EXTRACT}/echo_client"
C_LIB="${SDK_ROOT}/c/lib/${C_TARGET}"
C_INC="${SDK_ROOT}/c/include"

echo "verify_sdk: building Odin examples from SDK collection only"
odin build "$HOST_SRC" -collection:thirp="$COLLECTION" -out:"$HOST_BIN"
odin build "$CALLER_SRC" -collection:thirp="$COLLECTION" -out:"$CALLER_BIN"

echo "verify_sdk: building C example from SDK header and library only"
cc -o "$C_BIN" "$C_SRC" -I "$C_INC" -L "$C_LIB" -lthirp "-Wl,-rpath,$C_LIB"

echo "verify_sdk: scanning binaries for original repo path"
for bin in "$HOST_BIN" "$CALLER_BIN" "$C_BIN"; do
	if strings "$bin" | grep -F "$ROOT" >/dev/null; then
		echo "verify_sdk: ${bin} contains repo path ${ROOT}" >&2
		exit 1
	fi
done

echo "verify_sdk: C symbol agreement"
python3 - "$C_INC/thirp.h" "$C_LIB/libthirp.so" <<'PY'
import re, subprocess, sys

header, so = sys.argv[1], sys.argv[2]
text = open(header, encoding="utf-8").read()
header_syms = set(re.findall(r"THIRP_API\s+\S+\s+(thirp_\w+)\s*\(", text))
if not header_syms:
    raise SystemExit("verify_sdk: no THIRP_API symbols in header")
nm = subprocess.check_output(["nm", "-D", "--defined-only", so], text=True)
so_syms = set()
for line in nm.splitlines():
    parts = line.split()
    if len(parts) >= 3:
        so_syms.add(parts[-1])
missing = sorted(header_syms - so_syms)
if missing:
    raise SystemExit("verify_sdk: .so missing symbols: " + ", ".join(missing))
print("verify_sdk: header symbols present in libthirp.so")
PY

echo "verify_sdk: missing-dependency build must fail"
MISS="$(mktemp -d /tmp/thirp-runtime-sdk-miss.XXXXXX)"
cp -a "$SDK_ROOT" "$MISS/sdk"
rm -f "$MISS/sdk/odin/thirp/protocol/values.odin"
if odin build "$MISS/sdk/examples/odin/join_code_client" \
	-collection:thirp="$MISS/sdk/odin/thirp" \
	-out:"$MISS/should-not-exist" 2>/dev/null; then
	rm -rf "$MISS"
	echo "verify_sdk: build succeeded after deleting protocol/values.odin" >&2
	exit 1
fi
rm -rf "$MISS"
echo "verify_sdk: missing-dependency build failed as required"

wait_listening() {
	local log="$1"
	local i
	for i in $(seq 1 50); do
		if grep -q "thirp-broker listening on" "$log"; then
			sed -n 's/.*listening on \([^ ]*\).*/\1/p' "$log" | head -n1
			return 0
		fi
		sleep 0.1
	done
	echo "verify_sdk: broker did not print listen address" >&2
	cat "$log" >&2
	return 1
}

wait_join_code() {
	local log="$1"
	local i
	for i in $(seq 1 100); do
		if grep -q "^join_code: " "$log"; then
			sed -n 's/^join_code: //p' "$log" | head -n1
			return 0
		fi
		sleep 0.1
	done
	echo "verify_sdk: host did not print join_code" >&2
	cat "$log" >&2
	return 1
}

run_smoke() {
	local mode="$1"
	local work broker_log host_log broker_args host_args caller_args c_args
	local listen join_code

	work="$(mktemp -d /tmp/thirp-runtime-sdk-smoke.XXXXXX)"
	broker_log="${work}/broker.log"
	host_log="${work}/host.log"

	printf 'sdk-host-token\n' >"${work}/agent.token"
	printf 'sdk-caller-token\n' >"${work}/caller.token"
	chmod 600 "${work}/agent.token" "${work}/caller.token"

	if [[ "$mode" == insecure ]]; then
		cat >"${work}/broker.tokens" <<EOF
sdk-host-token=sdk-host:sdk;capabilities=register;label=sdk-host
sdk-caller-token=sdk-caller:sdk;capabilities=connect;label=sdk-caller
EOF
		chmod 600 "${work}/broker.tokens"
		broker_args=(
			--listen 127.0.0.1:0
			--insecure
			--token-file "${work}/broker.tokens"
			--policy-mode development
		)
		host_args=(--insecure --token-file "${work}/agent.token")
		caller_args=(--insecure --token-file "${work}/caller.token")
		c_args=(--insecure --token-file "${work}/caller.token")
	else
		openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
			-keyout "${work}/broker.key" -out "${work}/broker.crt" \
			-subj "/CN=127.0.0.1" \
			-addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
		cat >"${work}/broker.tokens" <<EOF
sdk-host-token=sdk-host:sdk;capabilities=register;label=sdk-host
sdk-caller-token=sdk-caller:sdk;capabilities=connect;label=sdk-caller
EOF
		chmod 600 "${work}/broker.tokens"
		broker_args=(
			--listen 127.0.0.1:0
			--tls-cert "${work}/broker.crt"
			--tls-key "${work}/broker.key"
			--token-file "${work}/broker.tokens"
			--policy-mode production
			--allow-register "sdk-host=sdk-demo/*"
			--allow-connect "sdk-caller=sdk-demo/*"
			--org-namespace "sdk=sdk-demo/*"
		)
		host_args=(--tls-ca "${work}/broker.crt" --token-file "${work}/agent.token")
		caller_args=(--tls-ca "${work}/broker.crt" --token-file "${work}/caller.token")
		c_args=(--tls-ca "${work}/broker.crt" --token-file "${work}/caller.token")
	fi

	echo "verify_sdk: smoke ${mode}"
	"$BROKER" "${broker_args[@]}" >"$broker_log" 2>&1 &
	BROKER_PID=$!
	listen="$(wait_listening "$broker_log")"
	if [[ -z "$listen" ]]; then
		cat "$broker_log" >&2
		kill -TERM "$BROKER_PID" 2>/dev/null || true
		wait "$BROKER_PID" 2>/dev/null || true
		BROKER_PID=""
		rm -rf "$work"
		return 1
	fi

	"$HOST_BIN" --broker "$listen" --namespace sdk-demo "${host_args[@]}" >"$host_log" 2>&1 &
	HOST_PID=$!
	join_code="$(wait_join_code "$host_log")"
	if [[ -z "$join_code" ]]; then
		cat "$host_log" >&2
		kill -TERM "$HOST_PID" 2>/dev/null || true
		wait "$HOST_PID" 2>/dev/null || true
		HOST_PID=""
		kill -TERM "$BROKER_PID" 2>/dev/null || true
		wait "$BROKER_PID" 2>/dev/null || true
		BROKER_PID=""
		rm -rf "$work"
		return 1
	fi

	"$CALLER_BIN" --broker "$listen" --namespace sdk-demo --join-code "$join_code" "${caller_args[@]}"
	"$C_BIN" --broker "$listen" --namespace sdk-demo --join-code "$join_code" "${c_args[@]}"

	kill -TERM "$HOST_PID" 2>/dev/null || true
	wait "$HOST_PID" 2>/dev/null || true
	HOST_PID=""
	kill -TERM "$BROKER_PID" 2>/dev/null || true
	wait "$BROKER_PID" 2>/dev/null || true
	BROKER_PID=""
	rm -rf "$work"
	echo "verify_sdk: smoke ${mode} ok"
}

run_smoke insecure
run_smoke tls

echo "verify_sdk: ok"
