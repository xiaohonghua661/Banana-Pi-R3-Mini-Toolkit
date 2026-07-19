#!/bin/sh
set -eu

script="$(CDPATH= cd "$(dirname "$0")" && pwd)/cleanup-approved-temp.sh"
root_a="/tmp/cleanup-approved-test-$$-a"
root_b="/tmp/cleanup-approved-test-$$-b"
target="/tmp/cleanup-approved-target-$$"
link="/tmp/cleanup-approved-link-$$"
out="/tmp/cleanup-approved-test-$$.out"
err="/tmp/cleanup-approved-test-$$.err"

cleanup() {
	rm -rf "$root_a" "$root_b" "$target" "$link"
	rm -f "$out" "$err"
}
trap cleanup EXIT HUP INT TERM

expect_refusal() {
	expected="$1"
	pattern="$2"
	shift 2
	set +e
	MSYS2_ARG_CONV_EXCL='*' sh "$script" "$@" >"$out" 2>"$err"
	rc=$?
	set -e
	[ "$rc" -eq "$expected" ] || {
		echo "UNEXPECTED_EXIT=$rc EXPECTED=$expected" >&2
		return 1
	}
	grep -F "$pattern" "$err" >/dev/null
}

sh -n "$script"
echo "BASH_N=PASS"

mkdir -p "$root_a" "$root_b" "$target"
touch "$root_a/probe" "$root_b/probe" "$target/keep"

MSYS2_ARG_CONV_EXCL='*' sh "$script" "$root_a" "$root_b" >"$out"
grep -F "DRY_RUN_ONLY" "$out" >/dev/null
[ -e "$root_a/probe" ] && [ -e "$root_b/probe" ]
echo "BATCH_DRY_RUN=PASS"

MSYS2_ARG_CONV_EXCL='*' sh "$script" --apply "$root_a" "$root_b" >"$out"
grep -F "CLEANUP_APPLIED" "$out" >/dev/null
[ ! -e "$root_a" ] && [ ! -e "$root_b" ]
echo "BATCH_APPLY=PASS"

MSYS2_ARG_CONV_EXCL='*' sh "$script" "$root_a" >"$out"
grep -F "SKIP_MISSING=$root_a" "$out" >/dev/null
echo "MISSING_IS_IDEMPOTENT=PASS"

expect_refusal 2 "usage:" || exit 1
echo "EMPTY_ARGUMENTS=PASS"

expect_refusal 3 "REFUSE_OUTSIDE_TMP=/etc" /etc
echo "OUTSIDE_REFUSAL=PASS"

expect_refusal 3 "REFUSE_RESOLVED_OUTSIDE_TMP=/tmp/../etc" /tmp/../etc
echo "TRAVERSAL_REFUSAL=PASS"

expect_refusal 3 "REFUSE_NONCANONICAL=/tmp/../cleanup-approved-missing-$$" "/tmp/../cleanup-approved-missing-$$"
echo "MISSING_TRAVERSAL_REFUSAL=PASS"

expect_refusal 3 "REFUSE_NONCANONICAL=/tmp//cleanup-approved-missing-$$" "/tmp//cleanup-approved-missing-$$"
echo "MISSING_DOUBLE_SLASH_REFUSAL=PASS"

expect_refusal 3 "REFUSE_OUTSIDE_TMP=/tmp/" /tmp/
echo "TMP_ROOT_REFUSAL=PASS"

ln -s "$target" "$link"
expect_refusal 3 "REFUSE_NONCANONICAL=$link" "$link"
[ -e "$target/keep" ]
echo "SYMLINK_REFUSAL=PASS"

echo "CLEANUP_SCRIPT_BLACKBOX=PASS"
