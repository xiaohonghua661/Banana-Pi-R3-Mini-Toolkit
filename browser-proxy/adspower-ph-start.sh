#!/bin/sh
set -eu
source="$(uci -q get openclash.config.config_path)"
runtime="/etc/openclash/$(basename "$source")"
work=/tmp/r3mini-adspower-ph
if [ ! -s "$runtime" ] || [ ! -s /etc/adspower-ph/settings.yaml ]; then
    logger -t adspower-ph 'PROFILE_SOURCE_NOT_READY'
    exit 1
fi
mkdir -p "$work"
chmod 700 "$work"
ruby /usr/share/adspower-ph/build_profile.rb "$runtime" /etc/adspower-ph/settings.yaml "$work/config.yaml"
/usr/sbin/adspower-ph-core -t -d "$work" -f "$work/config.yaml" >/dev/null 2>&1
exec /usr/sbin/adspower-ph-core -d "$work" -f "$work/config.yaml"
