#!/bin/sh
# 离线黑盒：守住「受管件必须同时出现在部署清单与备份清单里」这条不变量。
# 只读仓库文本，不连接设备、不写设备、不产生截图。
#
# 存在理由：backup-router.sh 的路径清单是手写的，曾漏掉全部热点/出口受管件，
# 导致备份静默缺件——用它做克隆源会丢掉整个热点 UI 且不报错。
set -eu

# Git Bash 会把 /etc/... 之类的参数改写成 Windows 路径，这里全程禁用转换。
export MSYS2_ARG_CONV_EXCL='*'

here="$(CDPATH= cd "$(dirname "$0")" && pwd)"
root="$(CDPATH= cd "$here/../.." && pwd)"
backup="$here/backup-router.sh"
router_tree="$root/fan-dashboard/router"
deploy_fan="$root/fan-dashboard/deploy-router.sh"
deploy_hotspot="$root/fan-dashboard/deploy-hotspot-router.sh"
# router_backup.py 里也有一份手写路径清单，且它是克隆源的推荐抓取工具。
# 早期版本只守 backup-router.sh，导致这一份漏件不会被发现。
py_backup="$root/openclash-ui-patch/router_backup.py"

work="${TMPDIR:-/tmp}/test-backup-covers-$$"
mkdir -p "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

for f in "$backup" "$deploy_fan" "$deploy_hotspot" "$py_backup"; do
	[ -f "$f" ] || { echo "MISSING_INPUT=$f" >&2; exit 2; }
done
[ -d "$router_tree" ] || { echo "MISSING_INPUT=$router_tree" >&2; exit 2; }

sh -n "$backup"
echo "BACKUP_SYNTAX=PASS"

# 备份脚本 for 循环里收录的设备绝对路径
awk '
/^for path in \\$/ { on = 1; next }
on {
	if ($0 ~ /; do$/) { sub(/; do$/, ""); on = 0 }
	sub(/[[:space:]]*\\$/, "")
	gsub(/^[[:space:]]+|[[:space:]]+$/, "")
	if ($0 ~ /^\//) print
}
' "$backup" | sort -u > "$work/backup-paths.txt"
[ -s "$work/backup-paths.txt" ] || { echo "BACKUP_PATH_LIST_EMPTY" >&2; exit 1; }
printf 'BACKUP_PATHS=%s\n' "$(wc -l < "$work/backup-paths.txt" | tr -d ' ')"

# 仓库受管件树 -> 设备绝对路径（fan-dashboard/router/<rel> 即设备上的 /<rel>）
( cd "$router_tree" && find . -type f | sed 's|^\.||' ) | sort -u > "$work/tree-paths.txt"
printf 'ROUTER_TREE_FILES=%s\n' "$(wc -l < "$work/tree-paths.txt" | tr -d ' ')"

# 两个部署脚本实际推送的设备绝对路径
cat "$deploy_fan" "$deploy_hotspot" \
	| awk '$1 == "put" || $1 == "put_if_missing" { print $2 }' \
	| grep '^/' | sort -u > "$work/deploy-paths.txt"
printf 'DEPLOY_PATHS=%s\n' "$(wc -l < "$work/deploy-paths.txt" | tr -d ' ')"

fail=0

while IFS= read -r p; do
	grep -Fxq "$p" "$work/backup-paths.txt" || { echo "MISSING_FROM_BACKUP=$p" >&2; fail=1; }
done < "$work/tree-paths.txt"
[ "$fail" -eq 0 ] || exit 1
echo "TREE_COVERED_BY_BACKUP=PASS"

while IFS= read -r p; do
	grep -Fxq "$p" "$work/backup-paths.txt" || { echo "DEPLOYED_BUT_NOT_BACKED_UP=$p" >&2; fail=1; }
done < "$work/deploy-paths.txt"
[ "$fail" -eq 0 ] || exit 1
echo "DEPLOY_COVERED_BY_BACKUP=PASS"

while IFS= read -r p; do
	grep -Fxq "$p" "$work/tree-paths.txt" || { echo "DEPLOYED_BUT_NOT_IN_REPO_TREE=$p" >&2; fail=1; }
done < "$work/deploy-paths.txt"
[ "$fail" -eq 0 ] || exit 1
echo "DEPLOY_MATCHES_REPO_TREE=PASS"

# 指纹副本必须与本体逐字节一致。菜单 json 指向带指纹的文件名，两份一旦漂移，
# 页面会静默加载到旧代码，不报任何错。
for alias in $( cd "$router_tree" && find . -type f -name '*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*.js' | sed 's|^\./||' ); do
	base="$(printf '%s' "$alias" | sed -E 's/-[0-9a-f]{8,}\.js$/.js/')"
	if [ ! -f "$router_tree/$base" ]; then
		echo "ALIAS_WITHOUT_BASE=$alias" >&2
		fail=1
		continue
	fi
	if ! cmp -s "$router_tree/$alias" "$router_tree/$base"; then
		echo "ALIAS_CONTENT_DIVERGED=$alias vs $base" >&2
		fail=1
	fi
done
[ "$fail" -eq 0 ] || exit 1
echo "ALIAS_COPIES_CONSISTENT=PASS"

# router_backup.py 内嵌 shell 的 for p in 清单，同样要覆盖源码树。
awk '
/^for p in \\$/ { on = 1; next }
on {
	if ($0 ~ /; do$/) { sub(/; do$/, ""); on = 0 }
	sub(/[[:space:]]*\\$/, "")
	gsub(/^[[:space:]]+|[[:space:]]+$/, "")
	if ($0 ~ /^\//) print
}
' "$py_backup" | sort -u > "$work/pybackup-paths.txt"
[ -s "$work/pybackup-paths.txt" ] || { echo "PYBACKUP_PATH_LIST_EMPTY" >&2; exit 1; }
printf 'PYBACKUP_PATHS=%s\n' "$(wc -l < "$work/pybackup-paths.txt" | tr -d ' ')"

# router_backup.py 允许列目录（例如 /etc/config 覆盖其下全部文件），
# 所以命中判定是「精确相等」或「某条清单项是它的祖先目录」。
while IFS= read -r p; do
	if grep -Fxq "$p" "$work/pybackup-paths.txt"; then
		continue
	fi
	covered=0
	while IFS= read -r listed; do
		case "$p" in
			"$listed"/*) covered=1; break ;;
		esac
	done < "$work/pybackup-paths.txt"
	[ "$covered" -eq 1 ] || { echo "MISSING_FROM_PY_BACKUP=$p" >&2; fail=1; }
done < "$work/tree-paths.txt"
[ "$fail" -eq 0 ] || exit 1
echo "TREE_COVERED_BY_PY_BACKUP=PASS"

# 菜单 json 声明的 view path 必须在仓库树里存在对应 JS，否则部署上去就是
# "HTTP error 404 while loading class file"。管道里的 while 在子 shell 中执行，
# 用文件回传结果而不是变量。
: > "$work/menu-missing.txt"
for j in "$router_tree"/usr/share/luci/menu.d/*.json; do
	[ -f "$j" ] || continue
	sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$j" | while IFS= read -r vp; do
		case "$vp" in */*) ;; *) continue ;; esac
		[ -f "$router_tree/www/luci-static/resources/view/$vp.js" ] \
			|| echo "MENU_VIEW_MISSING=$vp <- $(basename "$j")" >> "$work/menu-missing.txt"
	done
done
if [ -s "$work/menu-missing.txt" ]; then
	cat "$work/menu-missing.txt" >&2
	exit 1
fi
echo "MENU_VIEWS_RESOLVE=PASS"

echo "BACKUP_COVERAGE_BLACKBOX=PASS"
