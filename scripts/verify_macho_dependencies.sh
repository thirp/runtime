#!/usr/bin/env bash
# Portable Mach-O load-command guard. Bash 3.2 + POSIX od; no otool required.
# Checks thin 32/64-bit and every slice of fat/fat64, either byte order.
set -euo pipefail
export LC_ALL=C
TREE="${1:?usage: verify_macho_dependencies.sh ARCHIVE_TREE}"
[[ -d "$TREE" ]] || { echo "macho_guard: missing tree: $TREE" >&2; exit 1; }
fail() { echo "macho_guard: FAIL $file: $*" >&2; exit 1; }
# Read only headers/load commands, never entire executable data segments.
read_bytes() {
	local offset="$1" count="$2"
	(( offset >= 0 && count >= 0 && offset <= file_size && count <= file_size-offset )) || fail 'truncated header/load commands'
	bytes=( $(od -An -v -tu1 -j "$offset" -N "$count" "$file") )
	[[ ${#bytes[@]} -eq $count ]] || fail 'short read'
}
uint() {
	local pos="$1" width="$2" endian="$3" i b
	value=0
	for ((i=0; i<width; i++)); do
		if [[ $endian == le ]]; then b=${bytes[pos+width-1-i]}; else b=${bytes[pos+i]}; fi
		# Reject sizes/offsets that would overflow signed Bash arithmetic.
		(( value <= 36028797018963967 )) || fail 'integer overflow'
		value=$((value*256+b))
	done
}
check_path() {
	local path="$1" candidate base
	case "$path" in
		*libssl*|*libcrypto*|*/opt/homebrew*|*/opt/local/*|*/usr/local/opt/openssl*|*Cellar*) fail "forbidden dependency: $path" ;;
	esac
	# Reject traversal even under an otherwise allowed root.
	case "/$path/" in *'/../'*|*'/./'*) fail "dependency traversal: $path" ;; esac
	case "$path" in
		/usr/lib/*|/System/Library/*) ;;
		@rpath/*|@loader_path/*|@executable_path/*)
			base=${path##*/}
			candidate=''
			while IFS= read -r -d '' shipped; do
				if [[ ${shipped##*/} == "$base" ]]; then candidate=$shipped; break; fi
			done < <(find "$TREE" -type f -print0)
			[[ -n "$candidate" ]] || fail "unshipped dependency: $path"
			;;
		*) fail "external dependency: $path" ;;
	esac
	echo "macho_guard: $file: $path"
}
check_thin() {
	local offset="$1" size="$2" magic endian header ncmds cmdbytes pos cmd length nameoff path j char terminated
	(( size >= 28 )) || fail 'short Mach-O slice'
	read_bytes "$offset" 28
	magic="${bytes[0]} ${bytes[1]} ${bytes[2]} ${bytes[3]}"
	case "$magic" in
		'207 250 237 254') endian=le; header=32 ;;
		'254 237 250 207') endian=be; header=32 ;;
		'206 250 237 254') endian=le; header=28 ;;
		'254 237 250 206') endian=be; header=28 ;;
		*) fail 'invalid Mach-O slice magic' ;;
	esac
	uint 16 4 "$endian"; ncmds=$value
	uint 20 4 "$endian"; cmdbytes=$value
	(( cmdbytes <= size-header && cmdbytes <= 16777216 && ncmds <= cmdbytes/8 )) || fail 'invalid load-command bounds'
	read_bytes "$((offset+header))" "$cmdbytes"
	pos=0
	while (( ncmds > 0 )); do
		(( pos+8 <= cmdbytes )) || fail 'truncated load command'
		uint "$pos" 4 "$endian"; cmd=$((value & 0x7fffffff))
		uint "$((pos+4))" 4 "$endian"; length=$value
		(( length >= 8 && length % 4 == 0 && length <= cmdbytes-pos )) || fail 'invalid load-command size'
		# LOAD_DYLIB, LOAD_WEAK_DYLIB, REEXPORT_DYLIB, LAZY_LOAD_DYLIB,
		# LOAD_UPWARD_DYLIB. LC_ID_DYLIB describes self, not a runtime dependency.
		case "$cmd" in
			12|24|31|32|35)
				(( length >= 24 )) || fail 'short dylib command'
				uint "$((pos+8))" 4 "$endian"; nameoff=$value
				(( nameoff >= 24 && nameoff < length )) || fail 'invalid dylib name offset'
				path=''; terminated=0
				for ((j=pos+nameoff; j<pos+length; j++)); do
					if (( bytes[j] == 0 )); then terminated=1; break; fi
					(( bytes[j] >= 32 && bytes[j] < 127 )) || fail 'non-printable dylib path'
					printf -v char '\\%03o' "${bytes[j]}"
					printf -v char '%b' "$char"
					path="$path$char"
				done
				(( terminated )) || fail 'unterminated dylib path'
				check_path "$path"
				;;
		esac
		pos=$((pos+length)); ncmds=$((ncmds-1))
	done
	(( pos == cmdbytes )) || fail 'load-command count/size mismatch'
}
check_file() {
	local magic endian width count i off size table
	file_size=$(wc -c < "$file")
	(( file_size >= 4 )) || return 0
	read_bytes 0 4
	magic="${bytes[0]} ${bytes[1]} ${bytes[2]} ${bytes[3]}"
	case "$magic" in
		'207 250 237 254'|'254 237 250 207'|'206 250 237 254'|'254 237 250 206'|\
		'202 254 186 190'|'190 186 254 202'|'202 254 186 191'|'191 186 254 202')
			# Native human-readable log, including on a rejected binary.
			if command -v otool >/dev/null 2>&1; then otool -L "$file"; fi ;;
	esac
	case "$magic" in
		'207 250 237 254'|'254 237 250 207'|'206 250 237 254'|'254 237 250 206')
			check_thin 0 "$file_size" ;;
		'202 254 186 190'|'190 186 254 202'|'202 254 186 191'|'191 186 254 202')
			case "$magic" in '202 254 186 '*) endian=be ;; *) endian=le ;; esac
			case "$magic" in *'191'|'191 '*) width=32 ;; *) width=20 ;; esac
			read_bytes 0 8; uint 4 4 "$endian"; count=$value
			(( count > 0 && count <= (file_size-8)/width && count <= 128 )) || fail 'invalid fat slice count'
			# Each thin parser replaces bytes, so reload each fat table entry.
			for ((i=0; i<count; i++)); do
				table=$((8+i*width)); read_bytes "$table" "$width"
				if (( width == 32 )); then
					uint 8 8 "$endian"; off=$value; uint 16 8 "$endian"; size=$value
				else
					uint 8 4 "$endian"; off=$value; uint 12 4 "$endian"; size=$value
				fi
				(( off >= 8+count*width && size <= file_size-off )) || fail 'invalid fat slice bounds'
				check_thin "$off" "$size"
			done ;;
		*) return 0 ;;
	esac
	seen=$((seen+1))
}
seen=0
# The required binaries must really be Mach-O, not text fixtures or symlinks.
for name in thirp-agent thirp-connect libthirp.dylib; do
	file="$TREE/$name"
	[[ -f "$file" && ! -L "$file" ]] || fail 'required regular Mach-O missing'
	before=$seen
	check_file
	(( seen > before )) || fail 'required binary is not Mach-O'
done
while IFS= read -r -d '' file; do
	case "$file" in "$TREE/thirp-agent"|"$TREE/thirp-connect"|"$TREE/libthirp.dylib") continue ;; esac
	check_file
done < <(find "$TREE" -type f -print0)
echo "macho_guard: PASS ($seen Mach-O files) $TREE"
