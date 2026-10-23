"""r3mini-traffic 的离线对照测试：Python 参照实现 + 构造场景。

参照实现与 ucode 版按同一规则聚合：
  clash：首份快照只做基线；同一连接 id 计数单调取差值，否则按新连接全计；核心计数回退视为重启；
         差额记「未归因」且负差额结转到下一轮；DIRECT/REJECT/PASS 出口归一。
  连接跟踪：同一轮重复的 key 只取第一条；缺席的 key 留墓碑（ESTABLISHED 与卸载中的流 500 轮，其余 20 轮）；
         再出现时计数不小于墓碑按增量，否则按新流；前 warmup 轮只建基线；从没见过且累计字节超过
         「(本轮时刻-首轮时刻) × 125 MB/s」的流只建基线；字节按「IP 层字节 − 包数 × 包头(tcp 52/udp 28)」估算载荷。
         socks = 原方向 dport 命中端口且目的为本机；forward = 源与目的都不是本机、回复方向被 SNAT 到本机地址
         且未被 DNAT，出口标 DIRECT@<SNAT 地址所在网卡>。卸载中的条目没有超时与状态两列。
  落盘：每进入一个小时开一段会话，文件 <日期>/<HH>.00000000.<序号>.tsv；小额目标折叠只作用于 clash/forward。
manage.py selftest 把同一份输入交给设备上的 ucode 版重放，逐行比对两边输出与文件名。

单独运行：python traffic-logger/test_replay.py   （生成构造场景并自检参照实现）
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

TZ = timezone(timedelta(hours=8))
NONPROXY = {"DIRECT", "REJECT", "REJECT-DROP", "PASS"}
DEFAULT_PORTS = {"10810": "ph-socks"}
DEFAULT_LOCAL = {"127.0.0.1": "lo", "192.168.0.242": "br-lan", "192.168.0.29": "eth1"}
CT_HEAD = re.compile(r"^ipv4 +[0-9]+ +([a-z]+) +[0-9]+ +([0-9]+ +)?([A-Z_]+ +)?")
CT_TUPLE = re.compile(r"src=([0-9.]+) dst=([0-9.]+) sport=([0-9]+) dport=([0-9]+) packets=([0-9]+) bytes=([0-9]+) "
                      r"(\[UNREPLIED\] )?src=([0-9.]+) dst=([0-9.]+) sport=([0-9]+) dport=([0-9]+) packets=([0-9]+) bytes=([0-9]+)")
CT_HDR = {"tcp": 52, "udp": 28}
LINE_RATE = 125000000
CT_EVERY = 15
TTL_LONG = (7500 + CT_EVERY - 1) // CT_EVERY
TTL_SHORT = (300 + CT_EVERY - 1) // CT_EVERY
MAX_ROWS = 5000
OVERFLOW_FOLD = 65536


def hour_start(t: int) -> int:
    return t - (t + 8 * 3600) % 3600


def clean(s) -> str:
    return re.sub(r"[\t\n\r]", " ", str(s))


class Oracle:
    def __init__(self, fold: int = 0, ports=None, local_ips=None, warmup: int = 1, forward: bool = True):
        self.fold = fold
        self.ports = dict(ports) if ports else dict(DEFAULT_PORTS)
        self.local = dict(local_ips) if local_ips else dict(DEFAULT_LOCAL)
        self.warmup = warmup
        self.forward = forward
        self.sess = None
        self.seq = 0
        self.out: dict[str, tuple[int, dict]] = {}
        self.prev = None
        self.last_up = self.last_down = 0
        self.carry_up = self.carry_down = 0
        self.ct_state: dict[str, list[int]] = {}
        self.ct_reads = 0
        self.ct_t0 = 0

    def path(self, h, seq):
        d = datetime.fromtimestamp(h, TZ)
        return d.strftime("%Y-%m-%d/%H") + f".00000000.{seq}.tsv"

    def add(self, src, kind, exit_, target, du, dd, n):
        key = "\t".join([clean(src), "-", kind, clean(exit_), clean(target)])
        r = self.sess["rows"].setdefault(key, [0, 0, 0])
        r[0] += du
        r[1] += dd
        r[2] += n

    def roll(self, ts):
        h = hour_start(ts)
        if self.sess and h != self.sess["h"]:
            self.write()
        if not self.sess or h != self.sess["h"]:
            self.seq += 1
            self.sess = {"h": h, "rows": {}, "path": self.path(h, self.seq)}

    def write(self):
        rows = self.sess["rows"]
        thr = self.fold or (OVERFLOW_FOLD if len(rows) > MAX_ROWS else 0)
        out = {}
        for k, r in rows.items():
            f = k.split("\t")
            if thr and f[2] in ("clash", "forward") and r[0] + r[1] < thr:
                f[4] = "(其他)"
            o = out.setdefault("\t".join(f), [0, 0, 0])
            for i in range(3):
                o[i] += r[i]
        self.out[self.sess["path"]] = (self.sess["h"], out)

    def clash(self, d):
        conns = d.get("connections") or []
        up, down = d.get("uploadTotal") or 0, d.get("downloadTotal") or 0
        first = self.prev is None
        restarted = not first and (up < self.last_up or down < self.last_down)
        nxt, adds, au, ad = {}, [], 0, 0
        for c in conns:
            cu, cd = c.get("upload") or 0, c.get("download") or 0
            nxt[c.get("id")] = (cu, cd)
            if first:
                continue
            p = self.prev.get(c.get("id"))
            du, dd, isnew = cu, cd, 1
            if p and cu >= p[0] and cd >= p[1]:
                du, dd, isnew = cu - p[0], cd - p[1], 0
            if not du and not dd and not isnew:
                continue
            m, ch = c.get("metadata") or {}, c.get("chains") or []
            exit_ = "DIRECT" if not ch else (ch[0] if ch[0] in NONPROXY else " < ".join(ch))
            host = m.get("host") or m.get("sniffHost") or m.get("destinationIP") or "?"
            port = str(m.get("destinationPort") or "")
            target = host if port in ("", "443", "80") else f"{host}:{port}"
            adds.append((m.get("sourceIP") or "?", exit_, target, du, dd, isnew))
            au += du
            ad += dd
        ru = rd = 0
        if not first:
            if restarted:
                self.carry_up = self.carry_down = 0
            ru = (up if restarted else up - self.last_up) - au + self.carry_up
            rd = (down if restarted else down - self.last_down) - ad + self.carry_down
            self.carry_up, self.carry_down = min(ru, 0), min(rd, 0)
            ru, rd = max(ru, 0), max(rd, 0)
        for a in adds:
            self.add(a[0], "clash", a[1], a[2], a[3], a[4], a[5])
        if ru or rd:
            self.add("-", "unattributed", "-", "-", ru, rd, 0)
        self.prev, self.last_up, self.last_down = nxt, up, down

    def conntrack(self, lines, t):
        self.ct_reads += 1
        if self.ct_reads == 1:
            self.ct_t0 = t
        warm = self.ct_reads <= self.warmup
        seen, adds = set(), []
        for line in lines:
            h = CT_HEAD.match(line)
            if not h or h[1] not in ("tcp", "udp"):
                continue
            m = CT_TUPLE.search(line)
            if not m:
                continue
            osrc, odst, osport, odport, opk, ob = m[1], m[2], m[3], m[4], int(m[5]), int(m[6])
            rsrc, rdst, rpk, rb = m[8], m[9], int(m[12]), int(m[13])
            if odport in self.ports and odst in self.local:
                kind, exit_, target = "socks", self.ports[odport], f"(SOCKS :{odport})"
            elif (self.forward and osrc not in self.local and odst not in self.local and rsrc == odst
                  and rdst != osrc and rdst in self.local):
                kind, exit_, target = "forward", "DIRECT@" + self.local[rdst], f"{odst}:{odport}"
            else:
                continue
            key = " ".join([h[1], osrc, osport, odst, odport])
            if key in seen:
                continue
            seen.add(key)
            st, hdr = self.ct_state.get(key), CT_HDR[h[1]]
            keep_long = (h[3] or "").strip() == "ESTABLISHED" or "OFFLOAD]" in line
            self.ct_state[key] = [ob, opk, rb, rpk, 0, TTL_LONG if keep_long else TTL_SHORT]
            if warm:
                continue
            isnew = 1
            if st and ob >= st[0] and opk >= st[1] and rb >= st[2] and rpk >= st[3]:
                du, dd, isnew = (ob - st[0]) - (opk - st[1]) * hdr, (rb - st[2]) - (rpk - st[3]) * hdr, 0
            elif not st and ob + rb > (t - self.ct_t0) * LINE_RATE:
                continue
            else:
                du, dd = ob - opk * hdr, rb - rpk * hdr
            du, dd = max(du, 0), max(dd, 0)
            if du or dd or isnew:
                adds.append((osrc, kind, exit_, target, du, dd, isnew))
        for k in list(self.ct_state):
            if k in seen:
                continue
            s = self.ct_state[k]
            s[4] += 1
            if s[4] > s[5]:
                del self.ct_state[k]
        for a in adds:
            self.add(*a)

    def replay(self, path) -> list[str]:
        pending, ct, ct_ts = None, None, 0

        def flush_ct():
            nonlocal ct
            if ct is not None:
                self.roll(ct_ts)
                self.conntrack(ct, ct_ts)
                ct = None

        for raw in open(path, encoding="utf-8"):
            line = raw.rstrip("\n")
            if not line:
                continue
            m = re.match(r"^@@(ct)? ([0-9]+)$", line)
            if m:
                flush_ct()
                if m[1]:
                    ct, ct_ts = [], int(m[2])
                else:
                    pending = int(m[2])
                continue
            if ct is not None:
                ct.append(line)
                continue
            if pending is not None and line.startswith("{"):
                self.roll(pending)
                self.clash(json.loads(line))
                pending = None
        flush_ct()
        if self.sess:
            self.write()
        return sorted(f"{h}\t{k}\t{r[0]}\t{r[1]}\t{r[2]}" for h, rows in self.out.values() for k, r in rows.items())

    def files(self) -> list[str]:
        return sorted(self.out)


def conn(cid, src, up, down, host="", port="443", chains=("DIRECT",), sniff="", dst_ip="1.2.3.4", meta=True):
    c = {"id": cid, "upload": up, "download": down, "chains": list(chains)}
    if meta:
        c["metadata"] = {"sourceIP": src, "host": host, "sniffHost": sniff, "destinationIP": dst_ip,
                         "destinationPort": port}
    return c


def ct_line(proto, src, sport, dst, dport, b_orig, b_reply, state="ESTABLISHED", unreplied=False,
            rsrc=None, rdst=None, rsport=None, rdport=None, flag="[ASSURED]", opk=0, rpk=0, offload=False):
    num = "6" if proto == "tcp" else "17"
    # 卸载中的条目没有超时与 TCP 状态两列
    head = f"{num} " if offload else f"{num} 7438 " + (f"{state} " if proto == "tcp" else "")
    mid = "[UNREPLIED] " if unreplied else ""
    return (f"ipv4     2 {proto}      {head}src={src} dst={dst} sport={sport} dport={dport} packets={opk} "
            f"bytes={b_orig} {mid}src={rsrc or dst} dst={rdst or src} sport={rsport or dport} dport={rdport or sport} "
            f"packets={rpk} bytes={b_reply} {'[HW_OFFLOAD]' if offload else flag} mark=0 zone=0 use=2")


def make_synthetic(path) -> None:
    """跨整点与午夜；clash：连接新增/关闭、核心重启、负差额结转、缺 metadata、带策略组的 DIRECT/REJECT；
    连接跟踪：端口复用、UNREPLIED、回复方向误命中、目的非本机、缺席一轮的墓碑、同轮重复行、超线速旧流、
    SNAT 转发流、透明代理(无 NAT)、重定向(DNAT)、本机发起。"""
    t0 = int(datetime(2026, 10, 23, 21, 59, 50, tzinfo=TZ).timestamp())
    t_mid = int(datetime(2026, 10, 23, 23, 59, 59, tzinfo=TZ).timestamp())
    node = ["🇹🇼 节点A", "🤖 AI组"]
    api_chain = ["n2", "g2", "root"]
    a = lambda up, down: conn("a1", "192.168.0.253", up, down, "chatgpt.com", chains=node)
    b = lambda up: conn("b1", "192.168.0.95", up, 20, "", "6688", dst_ip="1.2.3.4")
    c = lambda up, down: conn("c1", "192.168.0.253", up, down, "", "443", api_chain, sniff="api.anthropic.com")
    e = lambda up, down: conn("e1", "192.168.0.253", up, down, "chatgpt.com", "80", node)
    f1 = conn("f1", "", 5, 5, chains=(), meta=False)
    h1 = conn("h1", "192.168.0.253", 7, 3, "edge.microsoft.com", chains=["DIRECT", "🖥 Microsoft"])
    snaps = [
        (t0, 1000, 500, [a(100, 50), b(10)]),
        (t0 + 4, 1507, 603, [a(400, 80), b(10), c(50, 5), h1]),
        (t0 + 8, 1607, 653, [b(10), c(80, 9), h1, conn("d1", "192.168.0.29", 0, 0, "x.com", "8443", ["REJECT"]),
                             conn("g1", "192.168.0.29", 0, 0, "ads.com", chains=["REJECT", "🛑 广告"])]),
        (t0 + 12, 1707, 703, [b(15), c(180, 20)]),
        (t0 + 16, 40, 10, [e(30, 8)]),
        (t0 + 20, 90, 30, [e(70, 20), f1]),
        (t0 + 24, 100, 35, [e(85, 25), f1]),
        (t0 + 28, 120, 38, [e(95, 28), f1]),
        (t_mid, 130, 38, [e(105, 28), f1]),
        (t_mid + 4, 150, 38, [e(125, 28), f1]),
    ]
    big = 10 * 1024 ** 3
    fwd = lambda up, down: ct_line("tcp", "192.168.0.95", 55000, "93.184.216.34", 443, up, down, rdst="192.168.0.29")
    # 以下载为主的转发流：上传方向全是 52 字节的 ACK，估算载荷后应为 0
    ack = lambda ob, opk, rb, rpk: ct_line("tcp", "192.168.0.95", 56000, "203.0.113.9", 443, ob, rb,
                                           rdst="192.168.0.29", opk=opk, rpk=rpk)
    # 在普通 → 卸载 → 普通之间切换、跨整点的转发流
    off = lambda ob, rb, offload: ct_line("tcp", "192.168.0.95", 57000, "198.51.100.7", 443, ob, rb,
                                          rdst="192.168.0.29", offload=offload)
    noise = [
        ct_line("tcp", "192.168.0.253", 51111, "8.8.8.8", 443, 999, 999),                       # 无 NAT（透明代理形态）
        ct_line("tcp", "192.168.0.253", 10810, "1.1.1.1", 443, 777, 777),                       # 回复方向误命中 10810
        ct_line("tcp", "192.168.0.253", 57000, "1.2.3.4", 443, 888, 888, rsrc="192.168.0.242", rsport="7892"),  # DNAT
        ct_line("tcp", "192.168.0.29", 58000, "5.6.7.8", 443, 666, 666),                        # 本机发起
        ct_line("udp", "192.168.0.253", 56000, "8.8.8.8", 53, 70, 90),                           # 无 NAT 的 UDP
        ct_line("tcp", "192.168.0.95", 58000, "192.0.2.1", 443, 555, 555, rdst="10.9.9.9"),      # SNAT 到非本机地址
    ]
    cts = [
        (t0 + 1, [ct_line("tcp", "192.168.0.95", 50000, "192.168.0.242", 10810, 1000, 2000),
                  ct_line("udp", "192.168.0.253", 40000, "192.168.0.242", 10810, 60, 0, unreplied=True),
                  ct_line("tcp", "192.168.0.95", 52000, "8.8.4.4", 10810, 300, 300),
                  ct_line("tcp", "192.168.0.95", 53000, "192.168.0.242", 10810, 1000, 1000),
                  fwd(100, 100), ack(520, 10, 15000, 10), off(1000, 1000, False)] + noise),
        (t0 + 6, [ct_line("tcp", "192.168.0.95", 50000, "192.168.0.242", 10810, 5000, 9000),
                  ct_line("tcp", "192.168.0.95", 50000, "192.168.0.242", 10810, 5000, 9000),
                  ct_line("udp", "192.168.0.253", 40000, "192.168.0.242", 10810, 120, 0, unreplied=True),
                  ct_line("tcp", "192.168.0.29", 51000, "192.168.0.242", 10810, 300, 400, state="TIME_WAIT"),
                  ct_line("tcp", "192.168.0.95", 52000, "8.8.4.4", 10810, 900, 900),
                  ct_line("tcp", "192.168.0.95", 54000, "192.168.0.242", 10810, big, 0),
                  fwd(5100, 2100), ack(5720, 110, 165000, 110), off(3000, 2000, True)] + noise),
        (t0 + 13, [ct_line("tcp", "192.168.0.29", 51000, "192.168.0.242", 10810, 300, 400, state="TIME_WAIT"),
                   ct_line("tcp", "192.168.0.95", 50000, "192.168.0.242", 10810, 100, 200),
                   ct_line("tcp", "192.168.0.95", 53000, "192.168.0.242", 10810, 1500, 1300),
                   ct_line("tcp", "192.168.0.95", 54000, "192.168.0.242", 10810, big + 1000, 2000),
                   off(4000, 2500, False)] + noise),
    ]
    events = [(t, 0, s) for t, *s in snaps] + [(t, 1, l) for t, l in cts]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for t, kind, payload in sorted(events, key=lambda ev: ev[0]):
            if kind == 0:
                up, down, conns = payload
                fh.write(f"@@ {t}\n" + json.dumps({"uploadTotal": up, "downloadTotal": down, "connections": conns},
                                                  ensure_ascii=False) + "\n\n")
            else:
                fh.write(f"@@ct {t}\n" + "\n".join(payload) + "\n")


NODE = "🇹🇼 节点A < 🤖 AI组"
EXPECTED_SYNTHETIC = {
    # 21 点 clash：a1 +300/30；c1 新 50/5 +30/4；h1 新 7/3（DIRECT 带组归一）；d1、g1 新 0/0（REJECT 带组归一）；
    #             未归因 (507-357)/(103-38) + (100-30)/(50-4)
    ("21", "192.168.0.253", "clash", NODE, "chatgpt.com"): (300, 30, 0),
    ("21", "192.168.0.253", "clash", "n2 < g2 < root", "api.anthropic.com"): (80, 9, 1),
    ("21", "192.168.0.253", "clash", "DIRECT", "edge.microsoft.com"): (7, 3, 1),
    ("21", "192.168.0.29", "clash", "REJECT", "x.com:8443"): (0, 0, 1),
    ("21", "192.168.0.29", "clash", "REJECT", "ads.com"): (0, 0, 1),
    ("21", "-", "unattributed", "-", "-"): (220, 111, 0),
    # 21 点连接跟踪（首轮只建基线）：X +4000/7000（同轮重复只计一次），Y +60/0，V 新 300/400；
    #   54000 首见 10 GiB 超线速只建基线；8.8.4.4:10810 目的非本机不计；SNAT 到非本机地址不计；
    #   转发流 +5000/2000；ACK 流上传 5200-100×52=0、下载 150000-100×52；卸载中的流 +2000/1000
    ("21", "192.168.0.95", "socks", "ph-socks", "(SOCKS :10810)"): (4000, 7000, 0),
    ("21", "192.168.0.253", "socks", "ph-socks", "(SOCKS :10810)"): (60, 0, 0),
    ("21", "192.168.0.29", "socks", "ph-socks", "(SOCKS :10810)"): (300, 400, 1),
    ("21", "192.168.0.95", "forward", "DIRECT@eth1", "93.184.216.34:443"): (5000, 2000, 0),
    ("21", "192.168.0.95", "forward", "DIRECT@eth1", "203.0.113.9:443"): (0, 144800, 0),
    ("21", "192.168.0.95", "forward", "DIRECT@eth1", "198.51.100.7:443"): (2000, 1000, 0),
    # 22 点 clash：c1 +100/11，b1 +5/0（未归因 -5 结转，随后核心重启清零）；重启后 e1 新 30/8，再 +40/12 +15/5 +10/3；
    #             f1 新 5/5；未归因 0/39 + 10/2 + 5/3 + 0/0（-5 结转）+ (20-10-5)/0
    ("22", "192.168.0.253", "clash", "n2 < g2 < root", "api.anthropic.com"): (100, 11, 0),
    ("22", "192.168.0.95", "clash", "DIRECT", "1.2.3.4:6688"): (5, 0, 0),
    ("22", "192.168.0.253", "clash", NODE, "chatgpt.com"): (95, 28, 1),
    ("22", "?", "clash", "DIRECT", "?"): (5, 5, 1),
    ("22", "-", "unattributed", "-", "-"): (20, 44, 0),
    # 22 点连接跟踪：X 端口复用 100/200 新；53000 缺席一轮后按墓碑增量 +500/300；54000 增量 +1000/2000；
    #   卸载流恢复普通格式后 +1000/500
    ("22", "192.168.0.95", "socks", "ph-socks", "(SOCKS :10810)"): (1600, 2500, 1),
    ("22", "192.168.0.95", "forward", "DIRECT@eth1", "198.51.100.7:443"): (1000, 500, 0),
    # 23 点与次日 00 点：e1 +10、+20
    ("23", "192.168.0.253", "clash", NODE, "chatgpt.com"): (10, 0, 0),
    ("00", "192.168.0.253", "clash", NODE, "chatgpt.com"): (20, 0, 0),
}
EXPECTED_FILES = ["2026-10-23/21.00000000.1.tsv", "2026-10-23/22.00000000.2.tsv", "2026-10-23/23.00000000.3.tsv",
                  "2026-10-24/00.00000000.4.tsv"]


def self_check(path) -> None:
    o = Oracle()
    got = {}
    for line in o.replay(path):
        h, src, mac, kind, exit_, target, up, down, n = line.split("\t")
        hh = datetime.fromtimestamp(int(h), TZ).strftime("%H")
        got[(hh, src, kind, exit_, target)] = (int(up), int(down), int(n))
    if got != EXPECTED_SYNTHETIC or o.files() != EXPECTED_FILES:
        missing = {k: v for k, v in EXPECTED_SYNTHETIC.items() if got.get(k) != v}
        extra = {k: v for k, v in got.items() if k not in EXPECTED_SYNTHETIC}
        raise SystemExit(f"ORACLE_SELF_CHECK_FAILED missing={missing} extra={extra} files={o.files()}")
    print(f"ORACLE_SELF_CHECK_OK rows={len(got)} files={len(EXPECTED_FILES)}")


if __name__ == "__main__":
    import pathlib
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    out = pathlib.Path(__file__).resolve().parents[1] / "tmp" / "traffic-logger-test" / "synthetic.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    make_synthetic(out)
    self_check(out)
