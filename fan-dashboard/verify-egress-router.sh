#!/bin/sh

set -eu
umask 077

MODE="${1:-preflight}"
shift || true
MANAGER="${R3MINI_MANAGER:-/usr/sbin/r3mini-egress-manager}"
WEB="${R3MINI_WEB:-/usr/sbin/r3mini-hotspot-web}"
PROOF="${R3MINI_PROOF:-/tmp/r3mini-egress-proof.json}"
TMP="$(mktemp -d /tmp/r3mini-egress-verify.XXXXXX)"
trap 'rm -rf "$TMP"' 0 1 2 15

fail() { printf 'VERIFY_ERROR=%s\n' "$1" >&2; exit 1; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing_command:$1"; }

status_value() { "$WEB" status | jsonfilter -e "@.$1" 2>/dev/null || true; }

auto_decision() {
	local current="$1" best="$2" current_ms="$3" best_ms="$4" min_ms="$5" min_pct="$6" diff pct
	[ "$current" = "$best" ] && { printf 'lowest-delay'; return 0; }
	for value in "$current_ms" "$best_ms" "$min_ms" "$min_pct"; do is_uint "$value" || return 2; done
	[ "$current_ms" -gt 0 ] || return 2
	diff=$((current_ms - best_ms)); pct=$((diff * 100 / current_ms))
	[ "$diff" -lt "$min_ms" ] || [ "$pct" -lt "$min_pct" ] || return 1
	printf 'hysteresis-hold'
}

timing_event_matches() {
	local finished="$1" started="$2" elapsed="$3" action="$4" interface="$5" wanted="$6"
	is_uint "$finished" && is_uint "$started" && is_uint "$elapsed" || return 1
	[ "$finished" -ge "$started" ] && [ $((finished - started)) -eq "$elapsed" ] || return 1
	[ "$action" = "$wanted" ] && [ "$interface" = wan ]
}

verify_wan_failover() {
	local current fallback_field
	current="$(status_value egress_kind)"
	[ -n "$current" ] && [ "$current" != none ] && [ "$current" != wan ] || fail "timing_wan_failover_missing:$current"
	case "$current" in cellular) fallback_field=cellular_up;; hotspot) fallback_field=wwan_up;; *) fail "timing_fallback_invalid:$current";; esac
	[ "$(status_value "$fallback_field")" = true ] || fail "timing_fallback_offline:$current"
}

provider_digest() {
	local list="$TMP/providers" path source resolved
	: > "$list"
	yq e -r '.["proxy-providers"] // {} | .[] | (.path // "__MISSING__")' "$main_config" > "$TMP/provider-paths" || fail 'provider_paths_unreadable'
	while IFS= read -r path; do
		[ "$path" != __MISSING__ ] || fail 'provider_path_missing'
		case "/$path/" in */../*) fail 'provider_path_traversal';; esac
		case "$path" in /*) source="$path";; *) source="$main_home/$path";; esac
		resolved="$(readlink -f "$source" 2>/dev/null)" || fail 'provider_unreadable'
		[ -f "$resolved" ] || fail 'provider_not_regular'
		sha256sum "$resolved" | awk '{print $1}' >> "$list"
	done < "$TMP/provider-paths"
	sha256sum "$list" | awk '{print $1}'
}

snapshot() {
	local controller port secret base global
	find_main_process || fail 'production_core_not_found'
	controller="$(yq e -r '.["external-controller"] // ""' "$main_config")"
	secret="$(yq e -r '.secret // ""' "$main_config")"
	port="${controller##*:}"; is_uint "$port" || fail 'production_controller_not_tcp'
	base="http://127.0.0.1:$port"
	: > "$TMP/main.header"
	[ -z "$secret" ] || printf 'Authorization: Bearer %s\n' "$secret" > "$TMP/main.header"
	global="$(api_get "$base" "$TMP/main.header" /proxies/GLOBAL | yq -p=json e -r '.now // ""')"
	[ -n "$global" ] || fail 'production_global_unreadable'
	printf 'pid=%s\n' "$main_pid"
	printf 'config_sha=%s\n' "$(sha256sum "$main_config" | awk '{print $1}')"
	printf 'provider_sha=%s\n' "$(provider_digest)"
	printf 'global_sha=%s\n' "$(printf '%s' "$global" | sha256sum | awk '{print $1}')"
}

verify_probe_proof() {
	local state_id proof_id leaf_sha kind online_field delay pid device proof_ms kind_leaf expected_device seen_pids=''
	state_id="$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.proof_id' 2>/dev/null || true)"
	proof_id="$(jsonfilter -i "$PROOF" -e '@.proof_id' 2>/dev/null || true)"
	[ -n "$state_id" ] && [ "$proof_id" = "$state_id" ] || fail 'probe_proof_id_mismatch'
	leaf_sha="$(jsonfilter -i "$PROOF" -e '@.leaf_sha' 2>/dev/null || true)"
	printf '%s\n' "$leaf_sha" | grep -Eq '^[0-9a-f]{64}$' || fail 'probe_leaf_sha_invalid'
	for kind in wan cellular hotspot; do
		case "$kind" in wan) online_field=wired_wan_up;; cellular) online_field=cellular_up;; hotspot) online_field=wwan_up;; esac
		[ "$(status_value "$online_field")" = true ] || continue
		delay="$(jsonfilter -i /tmp/r3mini-egress-state.json -e "@.${kind}_ms" 2>/dev/null || true)"
		pid="$(jsonfilter -i "$PROOF" -e "@.${kind}_pid" 2>/dev/null || true)"
		device="$(jsonfilter -i "$PROOF" -e "@.${kind}_device" 2>/dev/null || true)"
		proof_ms="$(jsonfilter -i "$PROOF" -e "@.${kind}_ms" 2>/dev/null || true)"
		kind_leaf="$(jsonfilter -i "$PROOF" -e "@.${kind}_leaf_sha" 2>/dev/null || true)"
		expected_device="$(kind_dev "$kind" || true)"
		is_uint "$pid" && [ "$pid" -gt 1 ] || fail "probe_pid_invalid:$kind"
		case " $seen_pids " in *" $pid "*) fail "probe_pid_reused:$kind";; esac
		seen_pids="$seen_pids $pid"
		[ -n "$device" ] && [ "$device" = "$expected_device" ] || fail "probe_device_mismatch:$kind"
		is_uint "$delay" && [ "$proof_ms" = "$delay" ] || fail "probe_score_mismatch:$kind"
		[ "$kind_leaf" = "$leaf_sha" ] || fail "probe_leaf_mismatch:$kind"
	done
}

preflight() {
	local board hardlink_token hardlink_lock preferred
	[ "$(id -u)" = 0 ] || fail 'root_required'
	board="$(ubus call system board | jsonfilter -e '@.board_name')"
	[ "$board" = 'bananapi,bpi-r3-mini' ] || fail "unexpected_board:$board"
	for command in yq curl ss sha256sum readlink awk jsonfilter cmp find seq sort sed tail grep; do need "$command"; done
	yq --version | grep -Eq 'version v?4\.' || fail 'yq_v4_required'
	ss -H -lntp >/dev/null 2>&1 || fail 'ss_process_view_required'
	[ -x "$MANAGER" ] || fail 'manager_missing'
	[ -x "$WEB" ] || fail 'web_helper_missing'
	/etc/init.d/openclash status 2>/dev/null | grep -qx running || fail 'openclash_not_running'
	/etc/init.d/r3mini-hotspot status 2>/dev/null | grep -qx running || fail 'hotspot_service_not_running'
	hardlink_token="/var/lock/r3mini-verify-token.$$"; hardlink_lock="/var/lock/r3mini-verify-lock.$$"
	printf '%s\n' "$$" > "$hardlink_token"
	ln "$hardlink_token" "$hardlink_lock" 2>/dev/null || { rm -f "$hardlink_token"; fail 'hardlink_lock_unsupported'; }
	rm -f "$hardlink_token" "$hardlink_lock"
	export R3MINI_EGRESS_LIB=1
	. "$MANAGER"
	snapshot > "$TMP/preflight.snapshot"
	preferred="$(uci -q get r3mini_hotspot.main.preferred_egress || true)"
	case "$preferred" in auto|wan|cellular|hotspot) ;; *) preferred=auto;; esac
	printf 'PREFLIGHT=PASS\n'
	printf 'PREFERRED=%s\n' "$preferred"
	printf 'WAN_ONLINE=%s\n' "$(status_value wired_wan_up)"
	printf 'CELLULAR_ONLINE=%s\n' "$(status_value cellular_up)"
	printf 'HOTSPOT_ONLINE=%s\n' "$(status_value wwan_up)"
}

probe_check() {
	local before_updated status updated step residue found=0 kind online_field delay
	preflight
	snapshot > "$TMP/before.snapshot"
	before_updated="$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.updated_mono_ms' 2>/dev/null || true)"
	is_uint "$before_updated" || before_updated=0
	"$MANAGER" wake
	status=''; updated=0
	for step in $(seq 1 600); do
		status="$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.status' 2>/dev/null || true)"
		updated="$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.updated_mono_ms' 2>/dev/null || true)"
		if is_uint "$updated" && [ "$updated" -gt "$before_updated" ] && [ "$status" != probing ]; then found=1; break; fi
		sleep 0.2
	done
	[ "$found" = 1 ] || fail 'probe_timeout'
	case "$status" in ok|manual|failover) ;; *) fail "probe_status:$status";; esac
	for kind in wan cellular hotspot; do
		case "$kind" in wan) online_field=wired_wan_up;; cellular) online_field=cellular_up;; hotspot) online_field=wwan_up;; esac
		delay="$(jsonfilter -i /tmp/r3mini-egress-state.json -e "@.${kind}_ms" 2>/dev/null || true)"
		[ "$(status_value "$online_field")" != true ] || is_uint "$delay" || fail "online_delay_missing:$kind"
	done
	[ "$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.probe_target' 2>/dev/null || true)" = 'Claude + Anthropic' ] || fail 'probe_target_mismatch'
	verify_probe_proof
	snapshot > "$TMP/after.snapshot"
	cmp -s "$TMP/before.snapshot" "$TMP/after.snapshot" || fail 'production_openclash_changed'
	residue="$(find /tmp -maxdepth 1 -type d \( -name 'r3mini-clash-probe.*' -o -name 'r3mini-clash-discovery.*' \) -print -quit)"
	[ -z "$residue" ] || fail 'probe_temp_residue'
	printf 'PROBE_VERIFY=PASS\n'
	printf 'PROBE_STATUS=%s\n' "$status"
	printf 'WAN_MS=%s\n' "$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.wan_ms' 2>/dev/null || true)"
	printf 'CELLULAR_MS=%s\n' "$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.cellular_ms' 2>/dev/null || true)"
	printf 'HOTSPOT_MS=%s\n' "$(jsonfilter -i /tmp/r3mini-egress-state.json -e '@.hotspot_ms' 2>/dev/null || true)"
}

manual_check() {
	local target="$1" original online result kind restored=0
	case "$target" in wan) online=wired_wan_up;; cellular) online=cellular_up;; hotspot) online=wwan_up;; *) fail 'manual_target_invalid';; esac
	preflight
	[ "$(status_value "$online")" = true ] || fail "manual_target_offline:$target"
	original="$(uci -q get r3mini_hotspot.main.preferred_egress || true)"
	case "$original" in auto|wan|cellular|hotspot) ;; *) original=auto;; esac
	restore_manual() {
		[ "$restored" = 1 ] && return 0
		"$WEB" prefer "$original" >/dev/null 2>&1 || { printf 'VERIFY_ERROR=manual_restore_failed:%s\n' "$original" >&2; return 1; }
		[ "$(uci -q get r3mini_hotspot.main.preferred_egress)" = "$original" ] || { printf 'VERIFY_ERROR=manual_restore_unconfirmed:%s\n' "$original" >&2; return 1; }
		restored=1
	}
	cleanup_manual() {
		rc=$?
		trap - 0 1 2 15
		restore_manual || { sleep 0.1; restore_manual || rc=1; }
		rm -rf "$TMP"
		exit "$rc"
	}
	trap cleanup_manual 0
	trap 'exit 130' 1 2 15
	result="$("$WEB" prefer "$target")"
	kind="$(printf '%s' "$result" | jsonfilter -e '@.egress_kind')"
	[ "$kind" = "$target" ] || fail "manual_route_mismatch:$kind"
	[ "$(uci -q get r3mini_hotspot.main.preferred_egress)" = "$target" ] || fail 'manual_preference_not_saved'
	restore_manual
	printf 'MANUAL_VERIFY=PASS\n'
	printf 'TARGET=%s\n' "$target"
	printf 'RESTORED=%s\n' "$original"
}

auto_check() {
	local original restored=0 hold last now remaining current best='' best_ms='' kind delay current_ms min_ms min_pct decision decision_rc
	preflight
	original="$(uci -q get r3mini_hotspot.main.preferred_egress || true)"
	case "$original" in auto|wan|cellular|hotspot) ;; *) original=auto;; esac
	restore_auto() {
		[ "$restored" = 1 ] && return 0
		"$WEB" prefer "$original" >/dev/null 2>&1 || { printf 'VERIFY_ERROR=auto_restore_failed:%s\n' "$original" >&2; return 1; }
		[ "$(uci -q get r3mini_hotspot.main.preferred_egress)" = "$original" ] || { printf 'VERIFY_ERROR=auto_restore_unconfirmed:%s\n' "$original" >&2; return 1; }
		restored=1
	}
	cleanup_auto() {
		rc=$?
		trap - 0 1 2 15
		restore_auto || { sleep 0.1; restore_auto || rc=1; }
		rm -rf "$TMP"
		exit "$rc"
	}
	trap cleanup_auto 0
	trap 'exit 130' 1 2 15
	"$WEB" prefer auto >/dev/null
	hold="$(uci -q get r3mini_hotspot.main.auto_hold_seconds || true)"; is_uint "$hold" || hold=30
	[ "$hold" -le 300 ] || fail "auto_hold_too_large:$hold"
	last="$(jsonfilter -i /tmp/r3mini-egress-runtime -e '@.last_switch' 2>/dev/null || true)"; is_uint "$last" || last=0
	now="$(date +%s)"; remaining=$((hold - (now - last)))
	[ "$remaining" -le 0 ] || sleep "$remaining"
	probe_check
	probe_check
	probe_check
	for kind in wan cellular hotspot; do
		case "$kind" in wan) [ "$(status_value wired_wan_up)" = true ] || continue;; cellular) [ "$(status_value cellular_up)" = true ] || continue;; hotspot) [ "$(status_value wwan_up)" = true ] || continue;; esac
		delay="$(jsonfilter -i /tmp/r3mini-egress-state.json -e "@.${kind}_ms" 2>/dev/null || true)"
		is_uint "$delay" || fail "auto_delay_missing:$kind"
		if [ -z "$best_ms" ] || [ "$delay" -lt "$best_ms" ]; then best="$kind"; best_ms="$delay"; fi
	done
	[ -n "$best" ] || fail 'auto_no_online_score'
	current="$(status_value egress_kind)"
	current_ms="$(jsonfilter -i /tmp/r3mini-egress-state.json -e "@.${current}_ms" 2>/dev/null || true)"
	min_ms="$(uci -q get r3mini_hotspot.main.auto_min_improvement_ms || true)"; is_uint "$min_ms" || min_ms=20
	min_pct="$(uci -q get r3mini_hotspot.main.auto_min_improvement_pct || true)"; is_uint "$min_pct" || min_pct=15
	if decision="$(auto_decision "$current" "$best" "$current_ms" "$best_ms" "$min_ms" "$min_pct")"; then decision_rc=0; else decision_rc=$?; fi
	case "$decision_rc" in 0) ;; 1) fail "auto_best_not_selected:$best";; *) fail "auto_current_delay_missing:$current";; esac
	restore_auto
	printf 'AUTO_VERIFY=PASS\n'
	printf 'BEST=%s\nCURRENT=%s\nDECISION=%s\n' "$best" "$current" "$decision"
}

timing_check() {
	local trials="$1" wanted="$2" count=0 last finished started action interface elapsed step found p50_index p95_index p50 p95 max
	is_uint "$trials" && [ "$trials" -ge 1 ] && [ "$trials" -le 50 ] || fail 'timing_trials_invalid'
	case "$wanted" in ifup|ifdown|ifupdate|update|link) ;; *) fail 'timing_action_invalid';; esac
	preflight
	[ "$(uci -q get r3mini_hotspot.main.preferred_egress || true)" = auto ] || fail 'timing_requires_auto_preference'
	last="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.finished_ms' 2>/dev/null || true)"; is_uint "$last" || last=0
	: > "$TMP/samples"
	printf 'TIMING_WAIT action=%s trials=%s\n' "$wanted" "$trials"
	while [ "$count" -lt "$trials" ]; do
		found=0
		for step in $(seq 1 2400); do
			finished="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.finished_ms' 2>/dev/null || true)"
			started="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.started_ms' 2>/dev/null || true)"
			action="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.action' 2>/dev/null || true)"
			interface="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.interface' 2>/dev/null || true)"
			elapsed="$(jsonfilter -i /tmp/r3mini-egress-event.json -e '@.elapsed_ms' 2>/dev/null || true)"
			if is_uint "$finished" && [ "$finished" -gt "$last" ]; then
				last="$finished"
				if timing_event_matches "$finished" "$started" "$elapsed" "$action" "$interface" "$wanted"; then found=1; break; fi
			fi
			sleep 0.05
		done
		[ "$found" = 1 ] || fail 'timing_event_timeout'
		[ "$wanted" != ifdown ] || verify_wan_failover
		printf '%s\n' "$elapsed" >> "$TMP/samples"
		count=$((count + 1))
		printf 'TRIAL_%s_MS=%s\n' "$count" "$elapsed"
	done
	sort -n "$TMP/samples" > "$TMP/sorted"
	p50_index=$(((trials + 1) / 2)); p95_index=$(((trials * 95 + 99) / 100))
	p50="$(sed -n "${p50_index}p" "$TMP/sorted")"; p95="$(sed -n "${p95_index}p" "$TMP/sorted")"; max="$(tail -n 1 "$TMP/sorted")"
	printf 'P50_MS=%s\nP95_MS=%s\nMAX_MS=%s\n' "$p50" "$p95" "$max"
	[ "$p95" -le 500 ] && [ "$max" -le 1000 ] || fail 'timing_target_not_met'
	printf 'TIMING_VERIFY=PASS\n'
}

[ "${R3MINI_VERIFY_LIB:-0}" = 1 ] && return 0 2>/dev/null

case "$MODE" in
	preflight) preflight ;;
	probe) probe_check ;;
	manual) [ "$#" -eq 1 ] || fail 'manual_target_required'; manual_check "$1" ;;
	auto) [ "$#" -eq 0 ] || fail 'auto_takes_no_args'; auto_check ;;
	timing) [ "$#" -eq 2 ] || fail 'timing_args_required'; timing_check "$1" "$2" ;;
	*) fail 'usage:preflight|probe|manual <wan|cellular|hotspot>|auto|timing <trials> <action>' ;;
esac
