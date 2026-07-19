set -u

before="$(sha256sum /etc/config/r3mini_fan | cut -d' ' -f1)"
invalid_output="$(/usr/sbin/r3mini-fan-web apply 40 35 35 38 37 40 2>&1)"
invalid_code=$?
after="$(sha256sum /etc/config/r3mini_fan | cut -d' ' -f1)"
printf 'INVALID_EXIT=%s\n' "$invalid_code"
printf 'INVALID_MESSAGE=%s\n' "$invalid_output"
printf 'INVALID_CONFIG_UNCHANGED=%s\n' "$([ "$before" = "$after" ] && printf true || printf false)"

printf '%s\n' '===APPLY_CURRENT==='
/usr/sbin/r3mini-fan-web apply 30 35 35 38 37 40
printf '%s\n' '===MANUAL_HIGH==='
/usr/sbin/r3mini-fan-web mode high
printf '%s\n' '===BACK_TO_AUTO==='
/usr/sbin/r3mini-fan-web mode auto
