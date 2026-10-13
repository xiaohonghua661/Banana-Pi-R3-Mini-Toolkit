"""probe_pc.py —— 从本机直连 IP:443 做 TLS 握手（带指定域名 SNI），看 .242 的 OpenClash 拦不拦

本机默认网关是 .242，流量经 OpenClash 透明代理；mihomo 从 SNI 读出域名再按规则处理。
目标 IP 故意用不相干的地址（模拟 App 用 HTTPDNS / 内置 IP 直连），只有按 SNI 拦截才拦得住。
用法：python tmp/r3mini-adblock/test/probe_pc.py     输出每行：期望  实际  域名  来源
"""
import socket
import ssl

BAIDU = "153.3.238.127"
CASES = [
    # (期望, 目标 IP, SNI, 说明)
    ("BLOCK", "155.102.55.29", "ads3-normal-hl.zijieapi.com", "内置正则：字节广告接口"),
    ("BLOCK", "36.158.219.119", "v3-reading-ad.qznovelvod.com", "内置正则：红果广告视频"),
    ("BLOCK", "116.162.51.206", "dig.bdurl.net", "内置：字节 HTTPDNS"),
    ("BLOCK", BAIDU, "activity-ag.awemeughun.com", "内置域名清单（旧方案只在 DNS 层拦）"),
    ("BLOCK", BAIDU, "www.adsmoloco.com", "订阅：秋风广告规则"),
    ("OPEN", BAIDU, "www.baidu.com", "对照：百度"),
    ("OPEN", "36.157.194.145", "v5-dj-reading-video.qznovelvod.com", "对照：红果正片"),
    ("OPEN", BAIDU, "api5-normal-hl.amemv.com", "对照：抖音 API"),
    ("OPEN", BAIDU, "p3-tt.byteimg.com", "白名单：订阅里有，被剔除"),
]

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
bad = 0
for want, ip, sni, note in CASES:
    try:
        with socket.create_connection((ip, 443), timeout=6) as s, ctx.wrap_socket(s, server_hostname=sni) as t:
            t.do_handshake()
            got = "OPEN"
    except Exception as e:
        got = "BLOCK"
        note += " (%s)" % type(e).__name__
    bad += got != want
    print("%-5s %-5s %s %-36s %s" % (want, got, "ok  " if got == want else "DIFF", sni, note))
print("PROBE_ALL_AS_EXPECTED" if bad == 0 else "PROBE_DIFF=%d" % bad)
