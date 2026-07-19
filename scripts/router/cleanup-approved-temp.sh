#!/bin/sh
set -eu

usage() {
	echo "usage: $0 [--apply] /tmp/path [...]" >&2
	exit 2
}

apply=0
if [ "${1:-}" = "--apply" ]; then
	apply=1
	shift
fi
[ "$#" -gt 0 ] || usage

for path in "$@"; do
	case "$path" in
		/tmp/?*) ;;
		*)
			echo "REFUSE_OUTSIDE_TMP=$path" >&2
			exit 3
			;;
	esac
	if [ -L "$path" ]; then
		echo "REFUSE_NONCANONICAL=$path" >&2
		exit 3
	fi

	if [ ! -e "$path" ]; then
		case "$path" in
			*//*|*/./*|*/../*|*/.|*/..|*/)
				echo "REFUSE_NONCANONICAL=$path" >&2
				exit 3
				;;
		esac
		echo "SKIP_MISSING=$path"
		continue
	fi

	canonical="$(readlink -f "$path" 2>/dev/null)" || {
		echo "PATH_RESOLUTION_FAILED=$path" >&2
		exit 3
	}
	case "$canonical" in
		/tmp/?*) ;;
		*)
			echo "REFUSE_RESOLVED_OUTSIDE_TMP=$path" >&2
			exit 3
			;;
	esac
	[ "$canonical" = "$path" ] || {
		echo "REFUSE_NONCANONICAL=$path" >&2
		exit 3
	}

	size_kib=$(du -sk "$canonical" 2>/dev/null | awk '{print $1}')
	echo "CANDIDATE_KIB=${size_kib:-0} PATH=$canonical"
	if [ "$apply" -eq 1 ]; then
		rm -rf "$canonical"
		[ ! -e "$canonical" ] || {
			echo "DELETE_FAILED=$canonical" >&2
			exit 4
		}
		echo "DELETED=$canonical"
	fi
done

if [ "$apply" -eq 1 ]; then
	echo "CLEANUP_APPLIED"
else
	echo "DRY_RUN_ONLY"
fi
