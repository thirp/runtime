#!/usr/bin/env bash
# Source from the repo root; also shared by Darwin tests/replay.
# Odin resolves foreign import paths relative to transport/openssl.odin's package.
macos_prepare_openssl() {
	if [[ $(uname -s) != Darwin ]]; then
		echo 'macos_openssl: must run on Darwin' >&2
		return 1
	fi
	if [[ ${OPENSSL_PREFIX+x} != x ]]; then
		OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null)" || OPENSSL_PREFIX=''
	fi
	if [[ -z "$OPENSSL_PREFIX" ]]; then
		echo 'macos_openssl: set OPENSSL_PREFIX to an OpenSSL 3 prefix containing lib/libssl.a and lib/libcrypto.a' >&2
		return 1
	fi
	OPENSSL_PREFIX="$(cd "$OPENSSL_PREFIX" && pwd)" || return 1
	export OPENSSL_PREFIX
	local host_arch stage_arch archive info token private sdk
	host_arch="$(uname -m)"
	case "$host_arch" in
		arm64) stage_arch=arm64 ;;
		x86_64) stage_arch=amd64 ;;
		*) echo "macos_openssl: unsupported Darwin arch: $host_arch" >&2; return 1 ;;
	esac
	for archive in libssl.a libcrypto.a; do
		if [[ ! -f "$OPENSSL_PREFIX/lib/$archive" ]]; then
			echo "macos_openssl: missing $OPENSSL_PREFIX/lib/$archive; dylibs alone are insufficient" >&2
			return 1
		fi
		info="$(lipo -info "$OPENSSL_PREFIX/lib/$archive")" || return 1
		if ! [[ " $info " == *" $host_arch "* ]]; then
			echo "macos_openssl: $archive does not contain host arch $host_arch: $info" >&2
			return 1
		fi
	done
	OPENSSL_VER="$("$OPENSSL_PREFIX/bin/openssl" version)" || return 1
	if [[ "$OPENSSL_VER" != 'OpenSSL 3.'* ]]; then
		echo "macos_openssl: expected OpenSSL 3 from prefix, got $OPENSSL_VER" >&2
		return 1
	fi
	# Never import a package-manager -L: even -lz could then load MacPorts zlib.
	# Fail closed on private dependencies we have not explicitly reviewed.
	OPENSSL_LINK_FLAGS='-framework Security -framework CoreFoundation'
	if [[ -f "$OPENSSL_PREFIX/lib/pkgconfig/libcrypto.pc" ]]; then
		private="$(sed -n 's/^Libs\.private:[[:space:]]*//p' "$OPENSSL_PREFIX/lib/pkgconfig/libcrypto.pc")"
		for token in $private; do
			case "$token" in
				# Name the SDK stub by path: a bare -lz follows the toolchain's -L
				# list (Clay's iMac Odin pulls /opt/local/lib/libz.1.dylib).
				-lz) sdk="$(xcrun --sdk macosx --show-sdk-path)" || return 1
					[[ -f "$sdk/usr/lib/libz.tbd" ]] || { echo "macos_openssl: missing $sdk/usr/lib/libz.tbd" >&2; return 1; }
					OPENSSL_LINK_FLAGS="$OPENSSL_LINK_FLAGS $sdk/usr/lib/libz.tbd" ;;
				*) echo "macos_openssl: unsupported libcrypto.pc Libs.private token: $token" >&2; return 1 ;;
			esac
		done
	fi
	OPENSSL_STAGE="transport/build/openssl-darwin-$stage_arch"
	mkdir -p "$OPENSSL_STAGE" || return 1
	# Package-manager archives are often 0444; a second prepare must still restage.
	rm -f "$OPENSSL_STAGE/libssl.a" "$OPENSSL_STAGE/libcrypto.a" || return 1
	cp "$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_STAGE/libssl.a" || return 1
	cp "$OPENSSL_PREFIX/lib/libcrypto.a" "$OPENSSL_STAGE/libcrypto.a" || return 1
	echo "macos_openssl: $OPENSSL_VER; prefix=$OPENSSL_PREFIX; stage=$OPENSSL_STAGE"
}
