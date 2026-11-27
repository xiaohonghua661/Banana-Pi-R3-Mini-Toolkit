# BEGIN R3MINI-MESL-RELAY
# MESL 订阅专用（2026-11-27）：按节点名把入口换成节点商中转，见 r3mini-mesl-relay help。
# 非 MESL 订阅、开关关着、中转不通时原样不动；失败只记日志，不影响后面的段。
if [ -x /usr/sbin/r3mini-mesl-relay ]; then
    R3MINI_MESL_RELAY=$(/usr/sbin/r3mini-mesl-relay hook "$CONFIG_FILE" 2>&1 | tail -n 1)
    LOG_TIP "R3MINI-MESL-RELAY: ${R3MINI_MESL_RELAY:-no output}"
fi
# END R3MINI-MESL-RELAY
