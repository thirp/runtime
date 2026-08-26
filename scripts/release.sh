#!/usr/bin/env bash
# Build a Linux release tree: binaries, source archive, SPDX SBOM,
# NOTICE, provenance, and SHA-256 checksums.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f VERSION.txt ]]; then
	echo "release: VERSION.txt is missing" >&2
	exit 1
fi

VERSION="$(tr -d '[:space:]' < VERSION.txt)"
if [[ ! "$VERSION" =~ ^0\.[0-9]+\.[0-9]+$ ]]; then
	echo "release: VERSION.txt must be 0.x.y, got: ${VERSION}" >&2
	exit 1
fi

COMMIT="$(git rev-parse HEAD)"
WORKTREE="clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
	WORKTREE="dirty"
fi

ODIN_VER="$(odin version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
# Keep in sync with docs/DEPENDENCIES.md Minimum.
MIN_ODIN_MONTH="2026-07"
if [[ "$ODIN_VER" =~ dev-([0-9]{4}-[0-9]{2}) ]]; then
	ODIN_MONTH="${BASH_REMATCH[1]}"
	if [[ "$ODIN_MONTH" < "$MIN_ODIN_MONTH" ]]; then
		echo "release: Odin ${ODIN_VER} is older than minimum dev-${MIN_ODIN_MONTH}" >&2
		exit 1
	fi
else
	echo "release: could not parse Odin month from: ${ODIN_VER}" >&2
	exit 1
fi

OPENSSL_VER="$(openssl version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
ARCH="$(uname -m)"
DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

OUT="${ROOT}/dist/thirp-runtime-${VERSION}"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "release: building ${VERSION} commit ${COMMIT} (${WORKTREE})"

# Quote so a SHA that starts with a digit is a string, not an integer.
odin build broker_cli -out:"${OUT}/thirp-broker" -define:THIRP_COMMIT="\"${COMMIT}\""
odin build agent_cli -out:"${OUT}/thirp-agent" -define:THIRP_COMMIT="\"${COMMIT}\""
odin build caller_cli -out:"${OUT}/thirp-connect" -define:THIRP_COMMIT="\"${COMMIT}\""
odin build web_ingress_cli -out:"${OUT}/thirp-web-ingress" -define:THIRP_COMMIT="\"${COMMIT}\""
odin build c_abi -build-mode:shared -out:"${OUT}/libthirp.so"
cp "${ROOT}/c_abi/thirp.h" "${OUT}/thirp.h"
cp "${ROOT}/web_ingress_cli/README.md" "${OUT}/web-ingress-README.md"
cp "${ROOT}/examples/production/web-ingress.conf" "${OUT}/web-ingress.conf"
cp "${ROOT}/examples/production/web-ingress.token.example" "${OUT}/web-ingress.token.example"
cp "${ROOT}/deploy/systemd/thirp-web-ingress.service" "${OUT}/thirp-web-ingress.service"

PUB_STAGE="${OUT}/.public-src"
PUB_PACK="${OUT}/.public-pack"
rm -rf "$PUB_STAGE" "$PUB_PACK"
mkdir -p "$PUB_STAGE" "${PUB_PACK}/thirp-runtime-${VERSION}"
bash "${ROOT}/scripts/stage_public_tree.sh" "$PUB_STAGE"
cp -a "${PUB_STAGE}/." "${PUB_PACK}/thirp-runtime-${VERSION}/"
tar -C "$PUB_PACK" -czf "${OUT}/thirp-runtime-${VERSION}.tar.gz" "thirp-runtime-${VERSION}"
bash "${ROOT}/scripts/stage_public_tree.sh" --check-archive "${OUT}/thirp-runtime-${VERSION}.tar.gz"
rm -rf "$PUB_STAGE" "$PUB_PACK"

cp "${ROOT}/LICENSE" "${OUT}/LICENSE"
cp "${ROOT}/NOTICE" "${OUT}/NOTICE"
cp "${ROOT}/docs/CHANGELOG.md" "${OUT}/CHANGELOG.md"
cp "${ROOT}/docs/DEPENDENCIES.md" "${OUT}/DEPENDENCIES.md"

sed -e "s/__VERSION__/${VERSION}/g" \
	-e "s/__COMMIT__/${COMMIT}/g" \
	-e "s/__DATE__/${DATE}/g" \
	"${ROOT}/scripts/sbom.spdx.json.in" > "${OUT}/thirp-runtime-${VERSION}.spdx.json"

cat > "${OUT}/PROVENANCE.txt" <<EOF
name: thirp-runtime
version: ${VERSION}
source_commit: ${COMMIT}
worktree: ${WORKTREE}
odin: ${ODIN_VER}
openssl: ${OPENSSL_VER}
target: linux ${ARCH}
build_command: scripts/release.sh
EOF

export ROOT VERSION OUT ARCH DATE
"${ROOT}/scripts/check_sdk_api.sh"
"${ROOT}/scripts/release_sdk.sh"
"${ROOT}/scripts/release_broker.sh"

(
	cd "$OUT"
	sha256sum \
		thirp-broker \
		thirp-agent \
		thirp-connect \
		thirp-web-ingress \
		libthirp.so \
		thirp.h \
		"thirp-runtime-${VERSION}.tar.gz" \
		"thirp-runtime-sdk-${VERSION}.tar.gz" \
		"thirp-runtime-broker-${VERSION}.tar.gz" \
		LICENSE \
		NOTICE \
		CHANGELOG.md \
		DEPENDENCIES.md \
		web-ingress-README.md \
		web-ingress.conf \
		web-ingress.token.example \
		thirp-web-ingress.service \
		"thirp-runtime-${VERSION}.spdx.json" \
		PROVENANCE.txt \
		> SHA256SUMS
)

THIRP_PUBLISH_GPG_FINGERPRINT="3B8559D8754FB3C5B21110C786897A405CF3D8C4"
if [[ -z "${THIRP_GPG_KEY:-}" ]]; then
	if gpg --list-secret-keys --with-colons "$THIRP_PUBLISH_GPG_FINGERPRINT" >/dev/null 2>&1; then
		THIRP_GPG_KEY="$THIRP_PUBLISH_GPG_FINGERPRINT"
	fi
fi
if [[ -n "${THIRP_GPG_KEY:-}" ]]; then
	if ! grep -q "$THIRP_PUBLISH_GPG_FINGERPRINT" "${ROOT}/docs/SECURITY.md"; then
		echo "release: signing fingerprint does not match docs/SECURITY.md" >&2
		exit 1
	fi
	gpg --detach-sign --armor --local-user "${THIRP_GPG_KEY}" \
		--output "${OUT}/SHA256SUMS.asc" "${OUT}/SHA256SUMS"
	gpg --verify "${OUT}/SHA256SUMS.asc" "${OUT}/SHA256SUMS"
	echo "release: signed SHA256SUMS with ${THIRP_GPG_KEY}"
else
	echo "release: GPG signatures not produced (publish key not in the agent; set THIRP_GPG_KEY)"
fi

(
	cd "$OUT"
	sha256sum -c SHA256SUMS
)

BROKER_VER="$("${OUT}/thirp-broker" --version)"
echo "release: ${BROKER_VER}"
if [[ "$BROKER_VER" != *"${VERSION}"* ]]; then
	echo "release: --version missing ${VERSION}" >&2
	exit 1
fi
if [[ "$BROKER_VER" != *"${COMMIT}"* ]]; then
	echo "release: --version missing commit ${COMMIT}" >&2
	exit 1
fi

INGRESS_VER="$("${OUT}/thirp-web-ingress" --version)"
echo "release: ${INGRESS_VER}"
if [[ "$INGRESS_VER" != *"${VERSION}"* ]]; then
	echo "release: thirp-web-ingress --version missing ${VERSION}" >&2
	exit 1
fi
if [[ "$INGRESS_VER" != *"${COMMIT}"* ]]; then
	echo "release: thirp-web-ingress --version missing commit ${COMMIT}" >&2
	exit 1
fi

SBOM="${OUT}/thirp-runtime-${VERSION}.spdx.json"
for needle in '"name": "thirp-runtime"' '"name": "OpenSSL"' 'Apache-2.0'; do
	if ! grep -q -F "$needle" "$SBOM"; then
		echo "release: SBOM missing ${needle}" >&2
		exit 1
	fi
done

for field in source_commit odin openssl target build_command; do
	if ! grep -q "^${field}:" "${OUT}/PROVENANCE.txt"; then
		echo "release: PROVENANCE.txt missing ${field}" >&2
		exit 1
	fi
done

export ROOT VERSION OUT ARCH
"${ROOT}/scripts/verify_sdk.sh"
"${ROOT}/scripts/verify_broker.sh"

echo "release: wrote ${OUT}"
