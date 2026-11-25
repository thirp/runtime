#!/usr/bin/env bash
# Clean-room Broker collection verification. No C ABI; Agent+Broker must compile.
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

BROKER_TAR="${OUT}/thirp-runtime-broker-${VERSION}.tar.gz"

if [[ ! -f "$BROKER_TAR" ]]; then
	echo "verify_broker: missing ${BROKER_TAR}" >&2
	exit 1
fi

EXTRACT="$(mktemp -d /tmp/thirp-broker-verify.XXXXXX)"
cleanup() {
	rm -rf "$EXTRACT"
}
trap cleanup EXIT

tar -xzf "$BROKER_TAR" -C "$EXTRACT"
BROKER_ROOT="${EXTRACT}/thirp-runtime-broker-${VERSION}"
if [[ ! -d "$BROKER_ROOT" ]]; then
	echo "verify_broker: tarball missing thirp-runtime-broker-${VERSION}/" >&2
	exit 1
fi

echo "verify_broker: extracted ${BROKER_ROOT}"

(
	cd "$BROKER_ROOT"
	sha256sum -c SHA256SUMS
)

python3 - "$BROKER_ROOT" <<'PY'
import hashlib, json, os, sys

root = sys.argv[1]
with open(os.path.join(root, "BROKER_MANIFEST.json"), encoding="utf-8") as f:
    manifest = json.load(f)

required = [
    "manifest_version",
    "project",
    "project_version",
    "protocol_version",
    "odin_min_version",
    "odin_collection_root",
    "public_packages",
    "support_packages",
    "files",
]
for key in required:
    if key not in manifest:
        raise SystemExit(f"verify_broker: manifest missing {key}")

if "c_abi" in manifest:
    raise SystemExit("verify_broker: c_abi must be absent from broker artifact")
if manifest["project"] != "thirp-runtime":
    raise SystemExit("verify_broker: project is not thirp-runtime")
if manifest["protocol_version"] != "1.0":
    raise SystemExit("verify_broker: protocol_version is not 1.0")
if manifest["odin_collection_root"] != "odin/thirp":
    raise SystemExit("verify_broker: odin_collection_root mismatch")
if manifest["public_packages"] != ["agent", "caller", "auth", "broker"]:
    raise SystemExit("verify_broker: public_packages mismatch")
if manifest["support_packages"] != ["protocol", "transport", "logging"]:
    raise SystemExit("verify_broker: support_packages mismatch")

declared = {}
for entry in manifest["files"]:
    path = entry["path"]
    declared[path] = entry
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        raise SystemExit(f"verify_broker: manifest path missing: {path}")
    size = os.path.getsize(full)
    if size != entry["size"]:
        raise SystemExit(f"verify_broker: size mismatch for {path}")
    h = hashlib.sha256()
    with open(full, "rb") as f:
        h.update(f.read())
    if h.hexdigest() != entry["sha256"]:
        raise SystemExit(f"verify_broker: sha256 mismatch for {path}")

skip = {"BROKER_MANIFEST.json", "SHA256SUMS"}
actual = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        rel = os.path.relpath(os.path.join(dirpath, name), root)
        if rel not in skip:
            actual.append(rel.replace("\\", "/"))
extra = sorted(set(actual) - set(declared))
missing = sorted(set(declared) - set(actual))
if extra:
    raise SystemExit("verify_broker: undeclared files: " + ", ".join(extra))
if missing:
    raise SystemExit("verify_broker: declared files missing: " + ", ".join(missing))

for needle in ("LICENSE", "NOTICE", "VERSION.txt", "docs/PROTOCOL.md", "docs/SDK.md", "docs/COMPATIBILITY.md"):
    if not os.path.isfile(os.path.join(root, needle)):
        raise SystemExit(f"verify_broker: missing {needle}")

with open(os.path.join(root, "VERSION.txt"), encoding="utf-8") as f:
    version = f.read().strip()
if version != manifest["project_version"]:
    raise SystemExit("verify_broker: VERSION.txt does not match project_version")

required_dirs = [
    "odin/thirp/agent",
    "odin/thirp/caller",
    "odin/thirp/protocol",
    "odin/thirp/transport",
    "odin/thirp/logging",
    "odin/thirp/auth",
    "odin/thirp/broker",
]
for d in required_dirs:
    if not os.path.isdir(os.path.join(root, d)):
        raise SystemExit(f"verify_broker: required directory missing: {d}")

forbidden_dirs = [
    "odin/thirp/config",
    "odin/thirp/c_abi",
    "odin/thirp/version",
    "odin/thirp/web_ingress",
    "odin/thirp/agent_cli",
    "odin/thirp/caller_cli",
    "odin/thirp/broker_cli",
    "c",
    "examples",
]
for d in forbidden_dirs:
    if os.path.isdir(os.path.join(root, d)):
        raise SystemExit(f"verify_broker: forbidden directory present: {d}")

for dirpath, _, filenames in os.walk(os.path.join(root, "odin")):
    for name in filenames:
        if name.endswith("_test.odin") or name == "test_helpers.odin":
            raise SystemExit(f"verify_broker: test file present: {os.path.join(dirpath, name)}")
        if name.endswith(".git"):
            raise SystemExit("verify_broker: git metadata present")

print("verify_broker: manifest ok")
PY

COLLECTION="${BROKER_ROOT}/odin/thirp"
CONSUMER_DIR="${EXTRACT}/consumer"
CONSUMER_SRC="${CONSUMER_DIR}/main.odin"
CONSUMER_BIN="${EXTRACT}/broker_consumer"
mkdir -p "$CONSUMER_DIR"

cat >"$CONSUMER_SRC" <<'ODIN'
package broker_verify

import ag "thirp:agent"
import auth "thirp:auth"
import broker "thirp:broker"
import cl "thirp:caller"

main :: proc() {
	reg: broker.Registry
	if broker.registry_init(&reg) != .None {
		return
	}
	defer broker.registry_destroy(&reg)

	store: auth.StaticTokenAuth
	if auth.auth_init(&store) != .None {
		return
	}
	defer auth.auth_destroy(&store)

	server: broker.Server
	broker.server_init(&server, &reg, auth.static_token_authenticator(&store))
	defer broker.server_destroy(&server)

	agent: ag.Agent
	caller: cl.Caller
	_ = agent
	_ = caller
}
ODIN

echo "verify_broker: building Agent+Broker consumer from broker collection only"
odin build "$CONSUMER_DIR" -collection:thirp="$COLLECTION" -out:"$CONSUMER_BIN"

echo "verify_broker: scanning binary for original repo path"
if strings "$CONSUMER_BIN" | grep -F "$ROOT" >/dev/null; then
	echo "verify_broker: ${CONSUMER_BIN} contains repo path ${ROOT}" >&2
	exit 1
fi

echo "verify_broker: missing-dependency build must fail"
MISS="$(mktemp -d /tmp/thirp-broker-miss.XXXXXX)"
cp -a "$BROKER_ROOT" "$MISS/broker"
rm -f "$MISS/broker/odin/thirp/protocol/values.odin"
if odin build "$CONSUMER_DIR" \
	-collection:thirp="$MISS/broker/odin/thirp" \
	-out:"$MISS/should-not-exist" 2>/dev/null; then
	rm -rf "$MISS"
	echo "verify_broker: build succeeded after deleting protocol/values.odin" >&2
	exit 1
fi
rm -rf "$MISS"
echo "verify_broker: missing-dependency build failed as required"

echo "verify_broker: ok"
