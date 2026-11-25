#!/bin/bash
# Prepare an ImmortalWrt ext4 factory image for the Pi 5 side gateway, entirely on image files:
# decompress, grow rootfs partition to ROOT_MB, e2fsck + resize2fs, add uci-defaults + authorized_keys.
# Usage: prep_iwrt.sh <src.img.gz> <out.img> <uci-defaults file> <pubkey file> [ROOT_MB]
set -euo pipefail
SRC="$1"; OUT="$2"; UCI="$3"; KEY="$4"; ROOT_MB="${5:-1024}"
W=/root/iwrt-prep
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
cleanup() { mountpoint -q "$W/mnt" && umount "$W/mnt" || true; [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT

rm -rf "$W"; mkdir -p "$W/mnt"
log "decompress $SRC"
set +e; gzip -dc "$SRC" > "$W/img"; rc=$?; set -e
# OpenWrt factory images carry trailing metadata; gzip reports rc=2 "trailing garbage ignored"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then log "gzip failed rc=$rc"; exit 1; fi
log "decompressed bytes=$(stat -c %s "$W/img") gzip_rc=$rc"
sfdisk -d "$W/img"

P2_START=$(sfdisk -d "$W/img" | sed -n 's/.*img2 : start= *\([0-9]*\),.*/\1/p')
[ -n "$P2_START" ] || { log 'cannot find partition 2'; exit 1; }
NEW_BYTES=$(( P2_START * 512 + ROOT_MB * 1024 * 1024 ))
log "p2_start=$P2_START new_image_bytes=$NEW_BYTES"
truncate -s "$NEW_BYTES" "$W/img"
echo ', +' | sfdisk --no-reread --no-tell-kernel -N 2 "$W/img" >/dev/null
sfdisk -d "$W/img" | grep img2

P2_SIZE=$(sfdisk -d "$W/img" | sed -n 's/.*img2 : start= *[0-9]*, size= *\([0-9]*\),.*/\1/p')
LOOP=$(losetup -f --show -o $(( P2_START * 512 )) --sizelimit $(( P2_SIZE * 512 )) "$W/img")
log "loop=$LOOP"
set +e; e2fsck -fy "$LOOP"; rc=$?; set -e
[ "$rc" -le 1 ] || { log "e2fsck rc=$rc"; exit 1; }
resize2fs "$LOOP"
mount "$LOOP" "$W/mnt"
df -h "$W/mnt" | tail -1

ULA=$(printf 'fd%02x:%02x%02x:%02x%02x::/48' $(od -An -N5 -tu1 /dev/urandom))
mkdir -p "$W/mnt/etc/uci-defaults"
sed "s#__ULA__#$ULA#" "$UCI" | tr -d '\r' > "$W/mnt/etc/uci-defaults/99-rpi5-sidegw"
chmod 755 "$W/mnt/etc/uci-defaults/99-rpi5-sidegw"
sh -n "$W/mnt/etc/uci-defaults/99-rpi5-sidegw" && log 'FRAGMENT_SYNTAX_OK'
mkdir -p "$W/mnt/etc/dropbear"
tr -d '\r' < "$KEY" > "$W/mnt/etc/dropbear/authorized_keys"
chmod 600 "$W/mnt/etc/dropbear/authorized_keys"
log "ula=$ULA"
ls -la "$W/mnt/etc/uci-defaults/" "$W/mnt/etc/dropbear/"
for f in etc/openwrt_release etc/config/dropbear etc/uci-defaults/50-root-passwd etc/uci-defaults/50-dropbear etc/uci-defaults/99-default-settings etc/uci-defaults/99-default-settings-chinese; do
	log "--- /$f"
	cat "$W/mnt/$f" 2>/dev/null || echo '(missing)'
done
sync
umount "$W/mnt"
losetup -d "$LOOP"; LOOP=

log "copy to $OUT"
cp "$W/img" "$OUT"
sha256sum "$OUT"
log 'PREP_OK'
