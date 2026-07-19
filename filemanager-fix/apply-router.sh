#!/bin/sh
set -eu

target="${1:-/mnt}"
config_file=/etc/config/filemanager
backup_dir=/root/filemanager-backups

case "$target" in
    /*) ;;
    *)
        echo "error_kind=invalid_target target_must_be_absolute" >&2
        exit 2
        ;;
esac

if [ ! -d "$target" ]; then
    echo "error_kind=missing_target target=$target" >&2
    exit 3
fi

old="$(uci -q get filemanager.@filemanager[0].currentDirectory || true)"
if [ "$old" = "$target" ]; then
    echo "FILEMANAGER_PATH_ALREADY_OK"
    echo "CURRENT_DIRECTORY=$target"
    exit 0
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup="$backup_dir/filemanager-$stamp.conf"
mkdir -p "$backup_dir"
cp -p "$config_file" "$backup"

rollback() {
    cp -p "$backup" "$config_file"
    echo "FILEMANAGER_PATH_ROLLED_BACK backup=$backup" >&2
}

if ! uci set "filemanager.@filemanager[0].currentDirectory=$target" ||
   ! uci commit filemanager; then
    rollback
    echo "error_kind=update_failed" >&2
    exit 4
fi

actual="$(uci -q get filemanager.@filemanager[0].currentDirectory || true)"
if [ "$actual" != "$target" ] || ! grep -Fq "option currentDirectory '$target'" "$config_file"; then
    rollback
    echo "error_kind=verify_failed expected=$target actual=$actual" >&2
    exit 5
fi

echo "FILEMANAGER_PATH_FIX_OK"
echo "PREVIOUS_DIRECTORY=$old"
echo "CURRENT_DIRECTORY=$actual"
echo "BACKUP=$backup"
