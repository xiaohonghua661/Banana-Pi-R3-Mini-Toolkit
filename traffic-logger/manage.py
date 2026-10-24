"""r3mini-traffic 记录器的本机侧管理脚本（可一次对多台路由器执行）。

  python traffic-logger/manage.py backup    HOST...            改前备份（DPAPI 加密）+ 改前快照清单
  python traffic-logger/manage.py selftest  HOST               设备 /tmp 里重放、查询、页面接口测试，与 Python 参照实现比对
  python traffic-logger/manage.py dryrun    HOST [SECONDS]     不安装，从 /tmp 试跑：覆盖率、CPU、内存、SIGTERM
  python traffic-logger/manage.py install   HOST...            核对身份与改前快照 → 安装 → 原有功能、LuCI 页面与快照验收
  python traffic-logger/manage.py verify    HOST...            运行状态、数据落盘、LuCI 页面、原有功能、快照差异
  python traffic-logger/manage.py upgrade   HOST...            已安装时替换脚本、服务定义与 LuCI 页面（保留配置与数据）并重启、验收
  python traffic-logger/manage.py rollback  HOST...            按最新备份把本模块恢复成改前原样（数据不动），快照须与备份逐项相等
  python traffic-logger/manage.py uninstall HOST... [--purge-data]   卸载并证明本模块以外的快照不变
  python traffic-logger/manage.py status    HOST
  python traffic-logger/manage.py report    HOST [report 参数...]
  python traffic-logger/manage.py check-backup BACKUP.tar.gz.dpapi [--extract DIR]   解密核对备份；--extract 才写出明文

每台的改前基线 = backups/router/ 下该主机最新的 *-before-traffic-logger.manifest.json。
快照比对分两部分：本模块的路径（脚本、服务、配置、开机链接、LuCI 菜单/ACL/页面、数据目录）按期望状态逐项核对，
其余路径必须与基线逐项相等。
"""
from __future__ import annotations

import fnmatch
import hashlib
import io
import json
import pathlib
import re
import shlex
import sys
import tarfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import paramiko
import win32crypt

import test_replay

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
BACKUP_DIR = ROOT / "backups" / "router"
WORK = ROOT / "tmp" / "traffic-logger-test"
TZ = timezone(timedelta(hours=8))

SCRIPT = "router/usr/sbin/r3mini-traffic"
CORE_FILES = [
    (SCRIPT, "/usr/sbin/r3mini-traffic", "755"),
    ("router/etc/init.d/r3mini-traffic", "/etc/init.d/r3mini-traffic", "755"),
]
CONFIG_FILE = ("router/etc/config/r3mini_traffic", "/etc/config/r3mini_traffic", "644")
MENU = ("router/usr/share/luci/menu.d/luci-app-r3mini-traffic.json", "/usr/share/luci/menu.d/luci-app-r3mini-traffic.json")
ACL = ("router/usr/share/rpcd/acl.d/luci-app-r3mini-traffic.json", "/usr/share/rpcd/acl.d/luci-app-r3mini-traffic.json")
VIEW_SRC = "router/www/luci-static/resources/view/status/r3mini-traffic.js"
VIEW_DIR = "/www/luci-static/resources/view/status"
VIEW_RE = re.compile(re.escape(VIEW_DIR) + r"/r3mini-traffic(-[0-9a-f]{10})?\.js")
MENU_PATH = '"path": "status/r3mini-traffic"'
ACL_GROUP = "luci-app-r3mini-traffic"
RC_LINKS = {"/etc/rc.d/S99r3mini-traffic": "../init.d/r3mini-traffic",
            "/etc/rc.d/K10r3mini-traffic": "../init.d/r3mini-traffic"}
DATA_DIR = "/mnt/mmcblk0p6/r3mini-traffic"
MODULE_PATHS = {dst for _, dst, _ in CORE_FILES} | {CONFIG_FILE[1], MENU[1], ACL[1], DATA_DIR} | set(RC_LINKS)

BACKUP_PATHS = ["/etc", "/usr/share/openclash", "/usr/lib/opkg/status",
                "/usr/lib/lua/luci/controller/openclash.lua", "/usr/lib/lua/luci/view/openclash"]
BACKUP_GLOBS = ["/usr/sbin/r3mini-*", "/usr/sbin/adspower-ph-*", "/usr/share/luci/menu.d/*r3mini*",
                "/usr/share/rpcd/acl.d/*r3mini*", "/www/luci-static/resources/view/system/r3mini-*",
                "/www/luci-static/resources/view/network/r3mini-*", VIEW_DIR + "/r3mini-*"]
REQUIRED_MEMBERS = ["etc/openclash/core/clash_meta", "etc/init.d/openclash", "etc/rc.d", "etc/config/openclash"]

# 改前/改后要逐项核对的状态：文件记 sha256，符号链接记目标，数据分区记一级目录
SNAPSHOT_DIRS = ["/etc/config", "/etc/init.d", "/etc/rc.d", "/usr/sbin", "/etc/crontabs",
                 "/usr/share/luci/menu.d", "/usr/share/rpcd/acl.d", VIEW_DIR]
SNAPSHOT_SCRIPT = r"""
set -u
for d in """ + " ".join(SNAPSHOT_DIRS) + r"""; do
  for p in "$d"/* ; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ -L "$p" ]; then printf 'L\t%s\t%s\n' "$p" "$(readlink "$p")";
    elif [ -f "$p" ]; then printf 'F\t%s\t%s\n' "$p" "$(sha256sum "$p" | cut -d' ' -f1)"; fi
  done
done
for p in /mnt/mmcblk0p6/*; do [ -e "$p" ] && printf 'D\t%s\t-\n' "$p"; done
"""

# 控制接口只在设备本机访问；密钥从 UCI 读进 0600 临时文件，不出现在命令行与本机输出里
API_SCRIPT = r"""
set -u
umask 077
h=/tmp/r3t-hdr.$$
trap 'rm -f "$h"' EXIT INT TERM
printf 'Authorization: Bearer %s\n' "$(uci -q get openclash.config.dashboard_password)" > "$h"
curl -sS --max-time 15 -H @"$h" "http://127.0.0.1:$(uci -q get openclash.config.cn_port || echo 9090)$1"
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def connect(host: str) -> paramiko.SSHClient:
    known = pathlib.Path.home() / ".ssh" / "known_hosts"
    if host not in paramiko.HostKeys(str(known)):
        raise SystemExit(f"PINNED_HOST_KEY_MISSING host={host}")
    private = (ROOT / "docs" / "私密" / "商家交付信息.md").read_text(encoding="utf-8")
    for password in dict.fromkeys([""] + re.findall(r"`([^`\s]{1,80})`", private)):
        client = paramiko.SSHClient()
        client.load_host_keys(str(known))
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(host, username="root", password=password, look_for_keys=False,
                           allow_agent=False, timeout=8, banner_timeout=8, auth_timeout=8)
            return client
        except paramiko.AuthenticationException:
            client.close()
        except Exception:
            client.close()
            raise
    raise SystemExit(f"SSH_LOGIN_FAILED host={host}")


def run(client: paramiko.SSHClient, command: str, *, data: bytes | None = None,
        timeout: int = 30, check: bool = True) -> tuple[int, bytes, bytes]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if data is not None:
        stdin.write(data)
    stdin.channel.shutdown_write()
    out, err = stdout.read(), stderr.read()
    rc = stdout.channel.recv_exit_status()
    if check and rc:
        raise RuntimeError(f"REMOTE_COMMAND_FAILED rc={rc} cmd={command[:120]!r} err={err[:400]!r}")
    return rc, out, err


def text(client: paramiko.SSHClient, command: str, **kw) -> str:
    return run(client, command, **kw)[1].decode("utf-8", "replace")


def api(client: paramiko.SSHClient, path: str) -> dict:
    return json.loads(text(client, "sh -s " + shlex.quote(path), data=API_SCRIPT.encode()))


TMP_SUFFIX = ".r3t-new"


def upload(client: paramiko.SSHClient, data: bytes, remote: str, mode: str) -> None:
    tmp = remote + TMP_SUFFIX
    run(client, f"cat > {shlex.quote(tmp)} && chmod {mode} {shlex.quote(tmp)} && mv {shlex.quote(tmp)} {shlex.quote(remote)}",
        data=data, timeout=180)


def local_file(rel: str) -> bytes:
    data = (HERE / rel).read_bytes()
    if b"\r" in data:
        raise SystemExit(f"CRLF_IN_FILE {rel}")
    return data


def view_fingerprint() -> str:
    return digest(local_file(VIEW_SRC))[:10]


def deploy_files(with_config: bool) -> list[tuple[str, bytes, str]]:
    """(远端路径, 内容, 权限)。LuCI 视图按内容指纹改名、菜单里的路径同步改写：浏览器按 URL 缓存视图，
    换了文件名才会取新版（与风扇页 system/r3mini-fan-<指纹> 同一做法，这里由部署时生成）。"""
    fp = view_fingerprint()
    menu = local_file(MENU[0]).decode()
    if menu.count(MENU_PATH) != 1:
        raise SystemExit(f"MENU_PATH_PLACEHOLDER_MISSING {MENU[0]} 须含一处 {MENU_PATH}")
    out = [(dst, local_file(rel), mode) for rel, dst, mode in CORE_FILES]
    if with_config:
        out.append((CONFIG_FILE[1], local_file(CONFIG_FILE[0]), CONFIG_FILE[2]))
    # 菜单最后写：中途断开时菜单仍指向旧的（还在的）视图，不会指向不存在的文件
    out += [(ACL[1], local_file(ACL[0]), "644"),
            (f"{VIEW_DIR}/r3mini-traffic-{fp}.js", local_file(VIEW_SRC), "644"),
            (MENU[1], menu.replace(MENU_PATH, MENU_PATH[:-1] + f'-{fp}"').encode(), "644")]
    return out


def is_module(path: str) -> bool:
    """本模块的路径，含上传中断留下的 <路径>.r3t-new（否则它会被当成外部改动，挡住之后所有命令）。"""
    if path.endswith(TMP_SUFFIX):
        path = path[:-len(TMP_SUFFIX)]
    return path in MODULE_PATHS or VIEW_RE.fullmatch(path) is not None


def leftovers(snap: dict, keep: set) -> list[str]:
    """该清掉的本模块残留：上传临时文件，以及不在 keep 里的旧指纹视图。"""
    return sorted(p for p in snap if is_module(p) and (p.endswith(TMP_SUFFIX) or (VIEW_RE.fullmatch(p) and p not in keep)))


def snapshot(client: paramiko.SSHClient) -> dict[str, list[str]]:
    lines = text(client, "sh -s", data=SNAPSHOT_SCRIPT.encode()).splitlines()
    return {line.split("\t")[1]: line.split("\t") for line in lines if line.count("\t") == 2}


def diff_snapshot(base: dict, now: dict) -> tuple[set, set, set]:
    return (set(now) - set(base), set(base) - set(now), {p for p in set(base) & set(now) if base[p] != now[p]})


def check_outside(base: dict, now: dict, code: str) -> None:
    """本模块以外的路径必须与基线逐项相等。"""
    keep = lambda s: {p: v for p, v in s.items() if not is_module(p)}  # noqa: E731
    added, removed, changed = diff_snapshot(keep(base["snapshot"]), keep(now))
    if added or removed or changed:
        raise SystemExit(f"{code} added={sorted(added)} removed={sorted(removed)} changed={sorted(changed)}")


def module_state(snap: dict) -> dict[str, list[str]]:
    return {p: v for p, v in snap.items() if is_module(p)}


def expect_installed(now: dict) -> list[str]:
    """已安装状态：代码与 LuCI 文件与本地这一版逐字节相同；配置存在（内容归用户）；开机链接与数据目录在；
    没有旧指纹的视图残留。返回不符项。"""
    want = {dst: digest(data) for dst, data, _ in deploy_files(False)}
    bad = []
    for dst, h in want.items():
        v = now.get(dst)
        if not v or v[0] != "F" or v[2] != h:
            bad.append(f"{dst}:{v[2][:12] if v else 'missing'}!={h[:12]}")
    if (now.get(CONFIG_FILE[1]) or ["?"])[0] != "F":
        bad.append(CONFIG_FILE[1] + ":missing")
    for link, target in RC_LINKS.items():
        if now.get(link) != ["L", link, target]:
            bad.append(f"{link}:{now.get(link)}")
    if DATA_DIR not in now:
        bad.append(DATA_DIR + ":missing")
    bad += [f"{p}:leftover" for p in leftovers(now, set(want))]
    return bad


def identity(client: paramiko.SSHClient) -> dict:
    return {k: text(client, cmd, check=False).strip() for k, cmd in [
        ("hostname", "uci -q get system.@system[0].hostname"),
        ("lan_ip", "uci -q get network.lan.ipaddr"),
        ("eth0_mac", "cat /sys/class/net/eth0/address"),
    ]}


def check_identity(client: paramiko.SSHClient, base: dict) -> None:
    ident = identity(client)
    expect = {k: base["identity"][k] for k in ("hostname", "lan_ip", "eth0_mac")}
    if ident != expect:
        raise SystemExit(f"IDENTITY_MISMATCH expect={expect} got={ident}")


def latest_manifest(host: str) -> dict:
    found = sorted(BACKUP_DIR.glob(f"router-backup-*-{host}-before-traffic-logger.manifest.json"))
    if not found:
        raise SystemExit(f"NO_BASELINE_BACKUP host={host}：先运行 backup")
    m = json.loads(found[-1].read_text(encoding="utf-8"))
    if m.get("snapshot_dirs") != SNAPSHOT_DIRS:
        raise SystemExit(f"BASELINE_OUTDATED {found[-1].name} 的快照不含 {sorted(set(SNAPSHOT_DIRS) - set(m.get('snapshot_dirs') or []))}"
                         "：先重新 backup")
    return m


def pc_checks() -> dict:
    """本机经路由器透明代理访问外网，代表局域网客户端的真实上网路径。"""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    out = {}
    try:
        out["pc_generate_204"] = opener.open("https://www.gstatic.com/generate_204", timeout=15).status
    except Exception as e:  # noqa: BLE001 — 记录失败原因即可
        out["pc_generate_204"] = f"ERR {type(e).__name__}"
    try:
        body = opener.open("https://www.cloudflare.com/cdn-cgi/trace", timeout=15).read().decode()
        out["pc_cloudflare_loc"] = dict(l.split("=", 1) for l in body.splitlines() if "=" in l).get("loc", "?")
    except Exception as e:  # noqa: BLE001
        out["pc_cloudflare_loc"] = f"ERR {type(e).__name__}"
    return out


def health(client: paramiko.SSHClient) -> dict:
    """#BAK 原有功能清单：改动前、改动后、回滚后、卸载后各取一次并比对。"""
    h = {"openclash_pid": text(client, "pidof clash", check=False).strip(),
         "openclash_status": text(client, "/etc/init.d/openclash status", check=False).strip()}
    svc = json.loads(text(client, "ubus call service list"))
    h["running_services"] = sorted(
        f"{name}:{sum(1 for i in v.get('instances', {}).values() if i.get('running'))}"
        for name, v in svc.items() if name != "r3mini-traffic"
        and any(i.get("running") for i in v.get("instances", {}).values()))
    h["luci_http"] = text(client, "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/cgi-bin/luci/", check=False)
    h["dns_resolves"] = "Name:" in text(client, "nslookup www.google.com 127.0.0.1 2>&1", check=False)
    h["socks_10810_listening"] = ":10810 " in text(client, "netstat -lnt 2>/dev/null", check=False)
    proxies = api(client, "/proxies")["proxies"]
    group = next((n for n in proxies if "AI" in n and proxies[n].get("now")), "GLOBAL")
    leaf = group
    for _ in range(8):
        nxt = proxies.get(leaf, {}).get("now")
        if not nxt:
            break
        leaf = nxt
    q = "/proxies/" + urllib.parse.quote(leaf, safe="") + "/delay?timeout=6000&url=" + urllib.parse.quote(
        "https://www.gstatic.com/generate_204", safe="")
    try:
        delay = api(client, q).get("delay", 0)
    except Exception:  # noqa: BLE001
        delay = 0
    h["node_delay_ok"] = delay > 0
    h.update(pc_checks())
    return h


def compare_health(before: dict, after: dict, strict: bool = True) -> list[str]:
    """strict：与紧挨着改动之前取的基线逐项相等。非 strict（单独 verify，基线可能是几天前的）：
    进程号与服务列表的变化只告警（OpenClash 自己重启过也会变），节点与外网不通仍判失败。"""
    diffs = [f"{k}: {before.get(k)!r} -> {after.get(k)!r}"
             for k in ("openclash_pid", "openclash_status", "running_services", "luci_http", "dns_resolves",
                       "socks_10810_listening") if before.get(k) != after.get(k)]
    bad = diffs if strict else []
    if diffs and not strict:
        print("HEALTH_DIFF_WARN " + "; ".join(diffs))
    if not after.get("node_delay_ok"):
        bad.append(f"node_delay_ok: {after.get('node_delay_ok')!r}")
    if after.get("pc_generate_204") != 204:
        bad.append(f"pc_generate_204: {after.get('pc_generate_204')!r}")
    return bad


def health_file(host: str) -> pathlib.Path:
    return WORK / f"{host}-health-before-install.json"


def health_gate(client: paramiko.SSHClient, host: str, label: str, strict: bool = True) -> None:
    before = json.loads(health_file(host).read_text(encoding="utf-8")) if health_file(host).exists() else None
    after = health(client)
    print(f"HEALTH_{label} " + json.dumps(after, ensure_ascii=False))
    # 没有改前基线（新检出、tmp/ 被清过）时没法比相等，节点延迟与本机外网仍必须通
    bad = compare_health(before, after, strict) if before else compare_health(after, after, False)
    if bad:
        raise SystemExit("HEALTH_REGRESSION " + "; ".join(bad))


def save_health(client: paramiko.SSHClient, host: str) -> None:
    before = health(client)
    WORK.mkdir(parents=True, exist_ok=True)
    health_file(host).write_text(json.dumps(before, ensure_ascii=False, indent=1), encoding="utf-8")
    print("HEALTH_BEFORE " + json.dumps(before, ensure_ascii=False))


# ---------------------------------------------------------------- LuCI 验收
LUCI_SCRIPT = r"""
set -u
v="$1"
o=/tmp/r3t-view.$$
printf 'VIEW_HTTP=%s\n' "$(curl -s -o "$o" -w '%{http_code}' "http://127.0.0.1${v#/www}")"
printf 'VIEW_SHA=%s\n' "$(sha256sum "$o" 2>/dev/null | cut -d' ' -f1)"
rm -f "$o"
curl -s -o /dev/null http://127.0.0.1/cgi-bin/luci/
for f in /tmp/luci-indexcache.*.json; do [ -f "$f" ] && { echo "@@INDEX $f"; cat "$f"; echo; }; done
"""


def menu_node(index_text: str) -> dict | None:
    """LuCI 按 menu.d 建好的菜单树（/tmp/luci-indexcache.<文件列表哈希>.json）里本页的节点。"""
    for block in index_text.split("@@INDEX ")[1:]:
        body = block.split("\n", 1)[1]
        try:
            tree = json.loads(body)
        except ValueError:
            continue
        node = tree.get("children", {}).get("admin", {}).get("children", {}).get("status", {}).get(
            "children", {}).get("r3mini-traffic")
        if node:
            return node
    return None


def acl_session_script(calls: list[tuple[str, str, list[str]]]) -> str:
    """建一个临时 rpcd 会话，按 ACL 文件的内容逐条授权（rpcd 在 root 登录时对每个 ACL 组做的就是这件事），
    再经 uhttpd 的 /ubus 走浏览器同一条路调 file exec。会话号只在设备上的 shell 变量里，结束即销毁。"""
    acl = json.loads(local_file(ACL[0]))
    grants = []
    for group, spec in acl.items():
        for mode in ("read", "write"):
            sec = spec.get(mode)
            if not sec:
                continue
            grants.append(("access-group", [[group, mode]]))
            for scope, objs in sec.items():
                if scope == "uci":
                    grants.append(("uci", [[o, mode] for o in objs]))
                else:
                    grants.append((scope, [[o, f] for o, fns in objs.items() for f in fns]))
    lines = ["set -u",
             "sid=$(ubus call session create '{\"timeout\":120}' | jsonfilter -e '@.ubus_rpc_session')",
             "[ -n \"$sid\" ] || { echo SESSION_CREATE_FAILED; exit 1; }",
             "trap 'ubus call session destroy \"{\\\"ubus_rpc_session\\\":\\\"$sid\\\"}\" >/dev/null 2>&1' EXIT"]
    for scope, objs in grants:
        lines.append(f"ubus call session grant \"{{\\\"ubus_rpc_session\\\":\\\"$sid\\\",\\\"scope\\\":\\\"{scope}\\\","
                     f"\\\"objects\\\":$(printf %s {shlex.quote(json.dumps(objs, ensure_ascii=False))})}}\" >/dev/null")
    for name, cmd, params in calls:
        body = json.dumps({"command": cmd, "params": params}, ensure_ascii=False)
        lines.append(f"printf '@@CALL {name}\\n'; curl -s http://127.0.0.1/ubus -H 'Content-Type: application/json' "
                     f"-d \"{{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"call\\\",\\\"params\\\":"
                     f"[\\\"$sid\\\",\\\"file\\\",\\\"exec\\\",$(printf %s {shlex.quote(body)})]}}\"; echo")
    return "\n".join(lines) + "\n"


def parse_calls(out: str) -> dict[str, dict]:
    res = {}
    for block in out.split("@@CALL ")[1:]:
        name, _, body = block.partition("\n")
        try:
            res[name] = json.loads(body.strip() or "{}")
        except ValueError:
            res[name] = {"raw": body.strip()[:200]}
    return res


def luci_checks(client: paramiko.SSHClient) -> list[str]:
    """页面三件套：视图静态文件可取且与本地一致；菜单树里有本页且指向该视图；
    按 ACL 授权的会话能调 web 接口、调不了别的命令。"""
    bad = []
    fp = view_fingerprint()
    view = f"{VIEW_DIR}/r3mini-traffic-{fp}.js"
    out = text(client, "sh -s " + shlex.quote(view), data=LUCI_SCRIPT.encode(), timeout=60)
    http = re.search(r"VIEW_HTTP=(\d*)", out)[1]
    sha = re.search(r"VIEW_SHA=([0-9a-f]*)", out)[1]
    ok = http == "200" and sha == digest(local_file(VIEW_SRC))
    print(f"LUCI_VIEW_{'OK' if ok else 'FAIL'} url={view[4:]} http={http} sha={sha[:12]}")
    bad += [] if ok else ["view"]
    node = menu_node(out)
    ok = bool(node) and node.get("action", {}).get("path") == f"status/r3mini-traffic-{fp}" and \
        ACL_GROUP in (node.get("depends", {}).get("acl") or [])
    print(f"LUCI_MENU_{'OK' if ok else 'FAIL'} node={json.dumps(node, ensure_ascii=False)[:200]}")
    bad += [] if ok else ["menu"]
    cli = "/usr/sbin/r3mini-traffic"
    calls = [("web_status", cli, ["web", "status"]), ("web_report", cli, ["web", "report", "--by", "device", "--proxy"]),
             ("deny_report", cli, ["report", "--json"]), ("deny_run", cli, ["run"]), ("deny_web_bare", cli, ["web"]),
             ("deny_other", "/bin/cat", ["/etc/shadow"])]
    res = parse_calls(text(client, "sh -s", data=acl_session_script(calls).encode(), timeout=90))

    def allowed(r: dict) -> dict | None:
        result = r.get("result") or []
        if len(result) == 2 and result[0] == 0 and result[1].get("code") == 0:
            try:
                return json.loads(result[1].get("stdout") or "")
            except ValueError:
                return None
        return None
    st, rep = allowed(res.get("web_status", {})), allowed(res.get("web_report", {}))
    denied = {k: (res.get(k, {}).get("result") == [6] or "error" in res.get(k, {}))
              for k in ("deny_report", "deny_run", "deny_web_bare", "deny_other")}
    ok = bool(st) and st.get("version_cli") == local_version() and bool(rep) and rep.get("version") == local_version() \
        and all(denied.values())
    print(f"LUCI_ACL_{'OK' if ok else 'FAIL'} web_status={st and st.get('state')} web_report_groups={rep and rep.get('groups')} "
          f"denied={denied}" + ("" if ok else f" raw={json.dumps(res, ensure_ascii=False)[:600]}"))
    bad += [] if ok else ["acl"]
    return bad


# ---------------------------------------------------------------- backup
def backup(host: str) -> None:
    stamp = datetime.now(TZ).strftime("%Y%m%d-%H%M%S")
    client = connect(host)
    try:
        board = json.loads(text(client, "ubus call system board"))
        meta = {key: text(client, cmd, check=False) for key, cmd in [
            ("packages", "opkg list-installed"), ("mtd", "cat /proc/mtd"), ("disk", "df -Pk"),
            ("mounts", "mount"), ("route", "ip route"),
            ("openclash_status", "/etc/init.d/openclash status"), ("openclash_pid", "pidof clash"),
        ]}
        # 服务列表只留名字与运行实例数：原始输出含进程环境变量（OpenClash 的密钥就在里面），不能明文落盘
        svc = json.loads(text(client, "ubus call service list"))
        meta["services"] = sorted(f"{n}:{sum(1 for i in (v.get('instances') or {}).values() if i.get('running'))}"
                                  for n, v in svc.items())
        if "running" not in meta["openclash_status"]:
            raise RuntimeError("BASELINE_OPENCLASH_NOT_RUNNING")
        ident = identity(client)
        installed = text(client, "[ -x /usr/sbin/r3mini-traffic ] && /usr/sbin/r3mini-traffic version", check=False).strip()
        before = snapshot(client)
        paths = [p for p in BACKUP_PATHS if run(client, "[ -e " + shlex.quote(p) + " ]", check=False)[0] == 0]
        for pattern in BACKUP_GLOBS:
            rc, out, _ = run(client, "ls -d " + pattern + " 2>/dev/null", check=False)
            if rc == 0:
                paths.extend(out.decode().split())
        archive = run(client, "tar -czf - " + " ".join(shlex.quote(p) for p in paths), timeout=180)[1]
        if snapshot(client) != before:
            raise RuntimeError("BASELINE_CHANGED_DURING_BACKUP")
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tf:
            members = {m.name.lstrip("./"): m for m in tf.getmembers()}
            checked = 0
            for path, (kind, _, value) in before.items():
                # 目录按前缀、通配按 fnmatch：rstrip("*") 只去掉末尾的 *，menu.d/*r3mini* 这类中间带 * 的会漏核
                if kind != "F" or not (any(path == p or path.startswith(p + "/") for p in BACKUP_PATHS)
                                       or any(fnmatch.fnmatchcase(path, g) for g in BACKUP_GLOBS)):
                    continue
                member = members.get(path.lstrip("/"))
                if member is None or digest(tf.extractfile(member).read()) != value:
                    raise RuntimeError("BACKUP_MEMBER_HASH_MISMATCH " + path)
                checked += 1
            for item in REQUIRED_MEMBERS:
                if not any(n == item or n.startswith(item + "/") for n in members):
                    raise RuntimeError("BACKUP_INCOMPLETE " + item)
            # 回滚只靠备份恢复本模块：快照里的每个本模块文件与链接都必须在归档里
            for path, (kind, _, value) in before.items():
                if is_module(path) and path != DATA_DIR:
                    member = members.get(path.lstrip("/"))
                    if member is None or (kind == "L" and member.linkname != value):
                        raise RuntimeError("BACKUP_MODULE_MEMBER_MISSING " + path)
        name = f"router-backup-{stamp}-{host}-before-traffic-logger"
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        dest = BACKUP_DIR / (name + ".tar.gz.dpapi")
        encrypted = win32crypt.CryptProtectData(archive, "Router before traffic logger", None, None, None, 0)
        with dest.open("xb") as stream:
            stream.write(encrypted)
        if digest(win32crypt.CryptUnprotectData(dest.read_bytes(), None, None, None, 0)[1]) != digest(archive):
            raise RuntimeError("BACKUP_DPAPI_VERIFY_FAILED")
        manifest = {"host": host, "stamp": stamp, "board": board,
                    "identity": dict(ident, openclash_pid=meta["openclash_pid"].strip()),
                    "installed_version": installed or None,
                    "archive": dest.name, "archive_sha256": digest(archive), "cipher_sha256": digest(encrypted),
                    "archive_bytes": len(archive), "archive_entries": len(members), "paths": paths,
                    "snapshot_dirs": SNAPSHOT_DIRS, "snapshot": before, "metadata": meta}
        (BACKUP_DIR / (name + ".manifest.json")).write_text(json.dumps(manifest, ensure_ascii=False, indent=1),
                                                            encoding="utf-8")
        print(f"BACKUP_OK host={host} hostname={ident['hostname']} entries={len(members)} bytes={len(archive)} "
              f"member_hashes_checked={checked} snapshot_items={len(before)} installed={installed or '-'} "
              f"module_items={sorted(module_state(before))}")
        print(f"BACKUP_SHA256={manifest['archive_sha256']}")
        print(f"BACKUP_PATH={dest}")
    finally:
        client.close()


# ---------------------------------------------------------------- selftest
# 维护场景：以 2026-10-23 为「今天」，保留 5 个日期。期望：
#   10-18 只有 .compacting 标记、没有同令牌 gz（中断在 mv 之前）→ 重做压缩；
#   10-19 标记与同令牌 gz 都在（中断在删目录之前）→ 只删目录，不重复压缩；
#   10-20 压缩并删目录；10-21 已有旧 gz 不改写，目录另压一份新 gz，查询求和；
#   10-22 空目录删除；10-10 因超出保留条数被删；10-23 不动
MAINTAIN_SETUP = r"""
set -eu
D=$1
mkdir -p $D/2026-10-18 $D/2026-10-19 $D/2026-10-20 $D/2026-10-21 $D/2026-10-22 $D/2026-10-23
printf '1792270800\t10.0.0.4\t-\tclash\tDIRECT\tredo.com\t1\t1\t1\n' > $D/2026-10-18/05.tsv
: > $D/2026-10-18/.compacting.bbbbbbbb-1
printf '1792357200\t10.0.0.5\t-\tclash\tDIRECT\tdone.com\t2\t2\t1\n' > $D/2026-10-19/05.tsv
: > $D/2026-10-19/.compacting.aaaaaaaa-1
printf '1792357200\t10.0.0.5\t-\tclash\tDIRECT\tdone.com\t2\t2\t1\n' | gzip -c > $D/2026-10-19.aaaaaaaa-1.tsv.gz
printf '1792432800\t10.0.0.1\t-\tclash\tDIRECT\ta.com\t1\t2\t1\n' > $D/2026-10-20/02.tsv
printf '1792436400\t10.0.0.1\t-\tclash\tDIRECT\tb.com\t3\t4\t1\n' > $D/2026-10-20/03.tsv
printf '1792519200\t10.0.0.2\t-\tclash\tDIRECT\told.com\t100\t100\t1\n1792522800\t10.0.0.2\t-\tclash\tDIRECT\tkeep.com\t5\t5\t1\n' | gzip -c > $D/2026-10-21.tsv.gz
printf '1792519200\t10.0.0.2\t-\tclash\tDIRECT\tnew.com\t7\t7\t1\n' > $D/2026-10-21/02.tsv
printf '1792692000\t10.0.0.3\t-\tclash\tDIRECT\ttoday.com\t9\t9\t1\n' > $D/2026-10-23/02.tsv
printf 'x\n' | gzip -c > $D/2026-10-10.tsv.gz
"""

# 输出截短：3000 个各约 230 字节的目标，JSON 远超 rpcd file exec 的 256 KiB 上限
CAP_AWK = r"""BEGIN { p = sprintf("%0200d", 0); for (i = 0; i < 3000; i++)
  printf "%d\t10.0.0.1\t-\tclash\tDIRECT\tt%d-%s.example\t%d\t1\t1\n", H, i, p, i + 1 }
"""


def selftest(host: str) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    synth = WORK / "synthetic.txt"
    test_replay.make_synthetic(synth)
    test_replay.self_check(synth)
    test_replay.report_self_check()
    real = WORK / "real-stream.txt"
    real.write_bytes((ROOT / "tmp" / "traffic-20261023" / "router-stream.txt").read_bytes().replace(b"\r\n", b"\n"))
    base = "/tmp/r3t-selftest"
    client = connect(host)
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"{name}_{'OK' if ok else 'FAIL'} {detail}".rstrip())

    try:
        run(client, f"rm -rf {base} && mkdir -p {base}")
        upload(client, local_file(SCRIPT), base + "/r3mini-traffic", "755")
        upload(client, real.read_bytes(), base + "/real.txt", "644")
        upload(client, synth.read_bytes(), base + "/synthetic.txt", "644")
        print("SYNTAX " + text(client, f"ucode -c -o /dev/null {base}/r3mini-traffic && echo OK", check=False).strip())
        local_ips = {l.split()[3].split("/")[0]: l.split()[1] for l in text(client, "ip -4 -o addr show").splitlines()
                     if " inet " in l}
        # 真实连接跟踪表：抓两份，间隔 6 秒，用本机 SSH(22)/DNS(53) 的流验证解析与本机目的地址过滤
        run(client, f"{{ echo \"@@ct $(date +%s)\"; cat /proc/net/nf_conntrack; sleep 6; "
                    f"echo \"@@ct $(date +%s)\"; cat /proc/net/nf_conntrack; }} > {base}/ct.txt", timeout=60)
        ct_local = WORK / "real-conntrack.txt"
        ct_local.write_bytes(run(client, f"cat {base}/ct.txt", timeout=60)[1])
        ct_ports = [("22", "ssh"), ("53", "dns")]
        cases = [("real", real, "/real.txt", 0, None), ("synthetic", synth, "/synthetic.txt", 0, None),
                 ("synthetic-fold", synth, "/synthetic.txt", 1000, None),
                 ("real-conntrack", ct_local, "/ct.txt", 0, ct_ports)]
        for name, src, remote_in, fold, ports in cases:
            out_dir = f"{base}/out-{name}"
            extra = f" --socks-port {','.join(p + ':' + l for p, l in ports)}" if ports else ""
            rc, _, err = run(client, f"{base}/r3mini-traffic replay {base}{remote_in} {out_dir} --fold {fold} "
                                     f"--ct-warmup 1{extra}", timeout=300, check=False)
            got = sorted(l for l in text(client, f"cat {out_dir}/*/*.tsv 2>/dev/null", check=False).splitlines() if l)
            oracle = test_replay.Oracle(fold=fold, ports=ports, local_ips=local_ips)
            want = oracle.replay(src)
            files = sorted(text(client, f"cd {out_dir} 2>/dev/null && ls */*.tsv", check=False).split())
            ok = rc == 0 and got == want and files == oracle.files()
            check("REPLAY", ok, f"case={name} fold={fold} rc={rc} rows_device={len(got)} rows_oracle={len(want)} "
                                f"files_device={files} files_oracle={oracle.files()}" +
                  ("" if ok else f" err={err.decode()[:600]!r}"))
            if not ok:
                for line in sorted(set(got) ^ set(want))[:10]:
                    print(("  device_only " if line in got else "  oracle_only ") + line)
            if name == "real-conntrack":
                check("CONNTRACK_SAMPLE_NONEMPTY", len(want) > 0, f"rows={len(want)}")
            if name == "real" and ok:
                date = datetime.fromtimestamp(int(want[0].split("\t")[0]), TZ).strftime("%Y-%m-%d")
                rep = text(client, f"{base}/r3mini-traffic report --data-dir {out_dir} --date {date} --by device "
                                   f"--tsv --top 1000", check=False).splitlines()
                dev = {}
                for line in want:
                    f = line.split("\t")
                    if f[3] != "unattributed":
                        d = dev.setdefault(f[1], [0, 0, 0])
                        for i, j in enumerate((6, 7, 8)):
                            d[i] += int(f[j])
                # report 给路由器自身地址加「(路由器本机)」后缀，比对时去掉
                got_rep = {l.split("\t")[0].replace(" (路由器本机)", ""): [int(x) for x in l.split("\t")[1:]]
                           for l in rep if l and not l.startswith("(")}
                check("REPORT", got_rep == dev, f"devices={len(got_rep)}")
        # 查询口径：4 天构造数据（同小时两段会话、gz、缺一天），JSON 与 TSV 都要与 test_replay.report 逐组相等，
        # 排序、合计、未归因、下拉候选（facets）、日期范围信息一并核对
        rd = f"{base}/rep"
        run(client, f"mkdir -p {rd}/data/2026-10-20 {rd}/data/2026-10-23")
        for rel, rows in test_replay.REPORT_FILES.items():
            body = "".join("\t".join(str(x) for x in r) + "\n" for r in rows).encode()
            if rel.endswith(".gz"):
                upload(client, body, f"{rd}/plain.tsv", "644")
                run(client, f"gzip -c {rd}/plain.tsv > {rd}/data/{rel} && rm {rd}/plain.tsv")
            else:
                upload(client, body, f"{rd}/data/{rel}", "644")
        upload(client, test_replay.REPORT_NODES.encode(), f"{rd}/nodes.yaml", "644")
        common = (f"{base}/r3mini-traffic report --data-dir {rd}/data --no-mount-check --nodes-file {rd}/nodes.yaml "
                  f"--top 1000 ")
        for name, args, kw in test_replay.REPORT_QUERIES:
            kw = dict(kw)
            days, sort, by = kw.pop("days", None), kw.pop("sort", "up"), kw.pop("by")
            want = test_replay.report(test_replay.report_rows(days), by, nodes=frozenset(["node.example"]), **kw)
            q = " ".join(shlex.quote(a) for a in args)
            rc, out, err = run(client, common + "--json " + q, check=False)
            j = json.loads(out) if rc == 0 else {}
            rows = {"  |  ".join(r["k"]): [r["up"], r["down"], r["conns"]] for r in j.get("rows", [])}
            order = ["  |  ".join(r["k"]) for r in j.get("rows", [])]
            facets = {d: {f["k"]: [f["up"], f["down"], f["conns"]] for f in j.get("facets", {}).get(d, [])}
                      for d in ("device", "exit")}
            tsv = text(client, common + "--tsv " + q, check=False).splitlines()
            tsv_rows = {l.split("\t")[0]: [int(x) for x in l.split("\t")[1:]] for l in tsv if l and not l.startswith("(")}
            ok = (rc == 0 and rows == want["groups"] and order == test_replay.report_order(want["groups"], sort)
                  and j["total"] == dict(zip(("up", "down", "conns"), want["total"]), rows=want["rows"])
                  and [j["unattributed"]["up"], j["unattributed"]["down"]] == want["unattributed"]
                  and facets == want["facets"] and tsv_rows == want["groups"]
                  and [l.split("\t")[0] for l in tsv if l and not l.startswith("(")] == order
                  and "(合计)\t%d\t%d\t%d" % tuple(want["total"]) in tsv
                  and "(未归因)\t%d\t%d\t0" % tuple(want["unattributed"]) in tsv)
            check("REPORT_QUERY", ok, f"case={name} groups={len(rows)}" + ("" if ok else
                  f" rc={rc} got={rows} want={want['groups']} order={order} facets={facets} err={err.decode()[:200]!r}"))
        rc, out, _ = run(client, common + "--json --date 2026-10-20..2026-10-23 --by date", check=False)
        j = json.loads(out) if rc == 0 else {}
        check("REPORT_RANGE_META", j.get("days") == 4 and j.get("dates") == ["2026-10-20", "2026-10-21", "2026-10-23"]
              and j.get("available") == {"first": "2026-10-20", "last": "2026-10-23", "count": 3},
              f"days={j.get('days')} dates={j.get('dates')} available={j.get('available')}")
        # 截短：JSON 超过 240000 字节时逐次减半明细行；截短后的输出能经 rpcd 的 file exec（256 KiB 上限）取回
        cap = f"{base}/cap"
        run(client, f"mkdir -p {cap}/2026-10-23")
        upload(client, CAP_AWK.encode(), f"{cap}/gen.awk", "644")
        h5 = int(datetime(2026, 10, 23, 5, tzinfo=TZ).timestamp())
        run(client, f"awk -v H={h5} -f {cap}/gen.awk > {cap}/2026-10-23/05.tsv")
        cap_args = ["report", "--data-dir", cap, "--no-mount-check", "--date", "2026-10-23", "--by", "target", "--json",
                    "--top", "5000"]
        rc, out, _ = run(client, f"{base}/r3mini-traffic " + " ".join(cap_args), check=False)
        j = json.loads(out) if rc == 0 else {"rows": []}
        rc2, out2, err2 = run(client, "ubus call file exec " + shlex.quote(json.dumps(
            {"command": f"{base}/r3mini-traffic", "params": cap_args})), check=False, timeout=60)
        via = json.loads(out2) if rc2 == 0 else {}
        check("JSON_CAP", rc == 0 and len(out) <= 240001 and j.get("clipped") is True and j.get("groups") == 3000
              and 0 < len(j["rows"]) < 3000 and via.get("code") == 0,
              f"bytes={len(out)} rows={len(j['rows'])} groups={j.get('groups')} ubus_rc={rc2} ubus_code={via.get('code')}")
        # 页面入口：拒绝路径类参数与非 web 子命令，错误只有一行原因；读真实数据目录（只读）
        for cmd, msg in [("web report --data-dir /tmp", "不接受 --data-dir"),
                         ("web report --nodes-file /etc/passwd", "不接受 --nodes-file"),
                         ("web report --json", "不接受 --json"), ("web run", "用法"), ("web report --top 501", "--top"),
                         ("web report --date 2026-02-30", "--date"), ("web report --sort x", "--sort"),
                         ("web report --from 5 --to 5", "--from")]:
            rc, _, err = run(client, f"{base}/r3mini-traffic {cmd}", check=False)
            e = err.decode("utf-8", "replace")
            check("WEB_GUARD", rc == 2 and msg in e and len(e.strip().splitlines()) == 1,
                  f"cmd={cmd!r} rc={rc} err={e.strip()[:80]!r}")
        rc, out, _ = run(client, f"{base}/r3mini-traffic web status", check=False)
        st = json.loads(out) if rc == 0 else {}
        check("WEB_STATUS", rc == 0 and st.get("state") in ("STATUS_OK", "STATUS_DEGRADED", "NOT_RUNNING")
              and st.get("version_cli") == local_version(), f"rc={rc} state={st.get('state')} running={st.get('version')}")
        today = st.get("today") or datetime.now(TZ).strftime("%Y-%m-%d")
        first = (st.get("data") or {}).get("first") or today
        rc, out, _ = run(client, f"{base}/r3mini-traffic web report --date {first}..{today} --by target --top 500",
                         check=False, timeout=60)
        rep = json.loads(out) if rc == 0 else {}
        check("WEB_REPORT_REAL", rc == 0 and rep.get("version") == local_version() and "facets" in rep,
              f"range={first}..{today} groups={rep.get('groups')} bytes={len(out)} elapsed_ms={rep.get('elapsed_ms')}")
        rc, out, _ = run(client, f"{base}/r3mini-traffic status --json --run-dir {base}/none", check=False)
        check("STATUS_JSON_NOT_RUNNING", rc == 1 and json.loads(out or b"{}").get("state") == "NOT_RUNNING", f"rc={rc}")
        # 维护：压缩、并存保留、空目录、按条数保留
        m = f"{base}/maint"
        run(client, f"sh -s {m}", data=MAINTAIN_SETUP.encode())
        now = int(datetime(2026, 10, 23, 12, 0, tzinfo=TZ).timestamp())
        rc, _, err = run(client, f"{base}/r3mini-traffic maintain --data-dir {m} --no-mount-check --now {now} "
                                 f"--retention-days 5", check=False)
        raw_list = sorted(text(client, f"cd {m} && ls -a -d * .* */* */.* 2>/dev/null | grep -vE '(^|/)\\.\\.?$'",
                               check=False).split())
        listing = sorted(re.sub(r"\.[0-9a-f]{8}-[0-9]+\.tsv\.gz$", ".<tok>.tsv.gz", x)
                         if "aaaaaaaa-1" not in x else x for x in raw_list)
        want_list = sorted(["2026-10-18.<tok>.tsv.gz", "2026-10-19.aaaaaaaa-1.tsv.gz", "2026-10-20.<tok>.tsv.gz",
                            "2026-10-21.<tok>.tsv.gz", "2026-10-21.tsv.gz", "2026-10-23", "2026-10-23/02.tsv"])
        check("MAINTAIN_LAYOUT", rc == 0 and listing == want_list, f"rc={rc} got={listing} err={err.decode()[:300]!r}")

        def targets(date: str) -> list[str]:
            rep = text(client, f"{base}/r3mini-traffic report --data-dir {m} --no-mount-check --date {date} "
                               f"--by target --tsv", check=False)
            return sorted(l.split("\t")[0] for l in rep.splitlines() if l and not l.startswith("("))
        gz20 = sorted(text(client, f"gzip -dc {m}/2026-10-20.*.tsv.gz", check=False).splitlines())
        check("MAINTAIN_GZ_CONTENT", len(gz20) == 2 and "a.com" in gz20[0] and "b.com" in gz20[1], f"lines={len(gz20)}")
        check("MAINTAIN_MERGE_SUM", targets("2026-10-21") == ["keep.com", "new.com", "old.com"],
              f"targets={targets('2026-10-21')}")
        rep19 = text(client, f"{base}/r3mini-traffic report --data-dir {m} --no-mount-check --date 2026-10-19 --tsv",
                     check=False)
        check("MAINTAIN_RECOVERY", targets("2026-10-18") == ["redo.com"] and "(合计)\t2\t2\t1" in rep19,
              f"redo={targets('2026-10-18')} done_total={[l for l in rep19.splitlines() if l.startswith('(合计)')]}")
        # 订阅节点直连：目标命中节点服务器的 DIRECT 行计入 --proxy 并标注
        nd = f"{base}/nodes"
        run(client, f"mkdir -p {nd}/data/2026-10-23 && printf 'proxies:\\n  - {{name: n1, server: node.example, port: 443}}\\n'"
                    f" > {nd}/cfg.yaml && printf '1792692000\\t10.0.0.9\\t-\\tclash\\tDIRECT\\tnode.example\\t1234\\t5\\t1\\n"
                    f"1792692000\\t10.0.0.9\\t-\\tclash\\tDIRECT\\tother.example\\t99\\t9\\t1\\n' > {nd}/data/2026-10-23/02.tsv")
        rep_nodes = text(client, f"{base}/r3mini-traffic report --data-dir {nd}/data --no-mount-check --date 2026-10-23 "
                                 f"--proxy --by exit,target --tsv --nodes-file {nd}/cfg.yaml", check=False)
        check("NODE_DIRECT_TAG", "订阅节点直连(DIRECT)  |  node.example [订阅节点]\t1234" in rep_nodes
              and "other.example" not in rep_nodes, repr(rep_nodes.splitlines()[:2]))
        # 时钟落后于已有数据：只维持基线，不写盘、不维护
        c = f"{base}/clock"
        run(client, f"mkdir -p {c}/2026-10-23 && touch {c}/2026-10-23/22.tsv")
        rc, _, err = run(client, f"{base}/r3mini-traffic run --data-dir {c} --run-dir {c}/run --no-mount-check "
                                 f"--duration 6 --clock-skew -17280000", timeout=60, check=False)
        dirs = sorted(text(client, f"cd {c} && ls", check=False).split())
        clog = text(client, f"cat {c}/r3mini-traffic.log", check=False)
        check("CLOCK_BEHIND", rc == 0 and "CLOCK_BEHIND_DATA" in clog and dirs == ["2026-10-23", "r3mini-traffic.log", "run"],
              f"rc={rc} dirs={dirs}")
        rc, _, err = run(client, f"{base}/r3mini-traffic status --run-dir {base}/none", check=False)
        check("STATUS_NOT_RUNNING", rc == 1 and b"NOT_RUNNING" in _, f"rc={rc}")
        # 单实例锁：同一 run_dir 已有存活实例时第二个必须立刻退出（timeout 兜底防挂住）
        lk = f"{base}/lock"
        out = text(client, f"mkdir -p {lk}; {base}/r3mini-traffic run --data-dir {lk}/data --run-dir {lk}/run "
                           f"--no-mount-check --duration 30 >/dev/null 2>&1 & P=$!; sleep 3; "
                           f"{base}/r3mini-traffic run --data-dir {lk}/data2 --run-dir {lk}/run --no-mount-check "
                           f"--duration 30 > {lk}/second.out 2>&1 & Q=$!; sleep 3; "
                           f"if kill -0 $Q 2>/dev/null; then echo SECOND_STILL_RUNNING; kill -TERM $Q; wait $Q; "
                           f"else wait $Q; echo SECOND_RC=$?; fi; cat {lk}/second.out; kill -TERM $P; wait $P; "
                           f"echo FIRST_RC=$?", timeout=60, check=False)
        # ucode 的 die() 退出码是 254
        check("SINGLE_INSTANCE_LOCK", "已在运行" in out and "SECOND_RC=254" in out and "FIRST_RC=0" in out,
              " ".join(l for l in out.splitlines() if "RC=" in l or "已在运行" in l))
    finally:
        run(client, f"rm -rf {base}", check=False)
        client.close()
    print("SELFTEST_" + ("PASS" if not failures else f"FAIL failures={failures}"))
    if failures:
        raise SystemExit(1)


# ---------------------------------------------------------------- dryrun
DRYRUN_SCRIPT = r"""
set -u
B=/tmp/r3t-dry
cd $B
CP=$(pidof clash | cut -d' ' -f1)
C0=$(cut -d' ' -f14-15 /proc/$CP/stat); U0=$(cut -d' ' -f1 /proc/uptime)
sleep 30
C1=$(cut -d' ' -f14-15 /proc/$CP/stat); U1=$(cut -d' ' -f1 /proc/uptime)
./r3mini-traffic run --data-dir $B/data --run-dir $B/run --no-mount-check --duration {secs} --socks-port 10810:ph-socks 2>$B/stderr.log &
P=$!
sleep 5
S1=$(cut -d' ' -f14-17 /proc/$P/stat); C2=$(cut -d' ' -f14-15 /proc/$CP/stat); T1=$(cut -d' ' -f1 /proc/uptime)
sleep {mid}
S2=$(cut -d' ' -f14-17 /proc/$P/stat); C3=$(cut -d' ' -f14-15 /proc/$CP/stat); T2=$(cut -d' ' -f1 /proc/uptime)
RSS=$(grep VmRSS /proc/$P/status | tr -s ' ' | cut -d' ' -f2)
wait $P
echo "RC=$? S1=$S1 S2=$S2 T1=$T1 T2=$T2 RSS_KB=$RSS"
echo "CORE C0=$C0 C1=$C1 U0=$U0 U1=$U1 C2=$C2 C3=$C3"
for i in 1 2; do
  ./r3mini-traffic run --data-dir $B/data2 --run-dir $B/run2 --no-mount-check --duration 60 --socks-port 10810:ph-socks 2>>$B/stderr2.log &
  P=$!
  sleep 8
  kill -TERM $P
  K0=$(cut -d' ' -f1 /proc/uptime)
  wait $P
  echo "TERM$i EXIT=$? KILL_AT=$K0 EXITED_AT=$(cut -d' ' -f1 /proc/uptime)"
  echo "@@FILE$i"
  for f in $B/data2/*/*.tsv; do echo "PART $(basename $f) $(md5sum < $f | cut -d' ' -f1) $(wc -l < $f)"; done
  echo "@@END$i"
done
"""


def ticks(out: str, key: str, n: int) -> int:
    return sum(int(x) for x in re.search(key + r"=((?:\d+ ?){" + str(n) + "})", out)[1].split())


def dryrun(host: str, secs: int) -> None:
    client = connect(host)
    try:
        run(client, "rm -rf /tmp/r3t-dry && mkdir -p /tmp/r3t-dry")
        upload(client, local_file(SCRIPT), "/tmp/r3t-dry/r3mini-traffic", "755")
        out = text(client, "sh -s", data=DRYRUN_SCRIPT.replace("{secs}", str(secs)).replace(
            "{mid}", str(max(secs - 10, 5))).encode(), timeout=secs + 180)
        rows = [l.split("\t") for l in text(client, "cat /tmp/r3t-dry/data/*/*.tsv", check=False).splitlines() if l]
        log = text(client, "cat /tmp/r3t-dry/data/r3mini-traffic.log", check=False)
        log2 = text(client, "cat /tmp/r3t-dry/data2/r3mini-traffic.log", check=False)
        status = text(client, "cat /tmp/r3t-dry/run/status.json", check=False)
    finally:
        run(client, "rm -rf /tmp/r3t-dry", check=False)
        client.close()
    m = dict(re.findall(r"(\w+)=([^ \n]+)", out))
    print("\n".join(l for l in out.splitlines() if not re.match(r"^\d+\t", l) and not l.startswith("@@")))
    cpu = (ticks(out, "S2", 4) - ticks(out, "S1", 4)) / 100 / (float(m["T2"]) - float(m["T1"])) * 100
    core_idle = (ticks(out, "C1", 2) - ticks(out, "C0", 2)) / 100 / (float(m["U1"]) - float(m["U0"])) * 100
    core_busy = (ticks(out, "C3", 2) - ticks(out, "C2", 2)) / 100 / (float(m["T2"]) - float(m["T1"])) * 100
    parts = {}
    for i in ("1", "2"):
        body = re.search(rf"@@FILE{i}\n(.*?)@@END{i}", out, re.S)[1]
        parts[i] = {f[1]: f[2] for f in (l.split() for l in body.splitlines()) if len(f) == 4 and f[0] == "PART"}
    # 重启后新进程只写自己的会话文件：第一次的文件必须原样保留，另有一份新文件
    kept = parts["1"] and all(parts["2"].get(k) == v for k, v in parts["1"].items())
    print(f"SESSION_FILES_{'OK' if kept and len(parts['2']) > len(parts['1']) else 'FAIL'} "
          f"run1={sorted(parts['1'])} run2={sorted(parts['2'])}")
    print(f"CORE_CPU_PCT without_logger={core_idle:.2f} with_logger={core_busy:.2f}")
    clash_up = sum(int(r[6]) for r in rows if r[3] == "clash")
    socks_up = sum(int(r[6]) for r in rows if r[3] == "socks")
    un_up = sum(int(r[6]) for r in rows if r[3] == "unattributed")
    cover = clash_up / (clash_up + un_up) * 100 if clash_up + un_up else 0
    print(f"DRYRUN rows={len(rows)} clash_up={clash_up} unattributed_up={un_up} socks_up={socks_up} "
          f"coverage_pct={cover:.1f} cpu_pct_one_core={cpu:.2f} rss_kb={m.get('RSS_KB')}")
    print("LOG_LINES:\n" + log.strip())
    print("TERM_TEST:\n" + log2.strip())
    print("STATUS " + status.strip()[:700])


# ---------------------------------------------------------------- install / verify / upgrade / rollback / uninstall
def wait_for(client: paramiko.SSHClient, cmd: str, pattern: str, seconds: int) -> str:
    deadline = time.time() + seconds
    last = ""
    while time.time() < deadline:
        last = text(client, cmd, check=False)
        if re.search(pattern, last):
            return last
        time.sleep(3)
    raise RuntimeError(f"WAIT_TIMEOUT cmd={cmd!r} pattern={pattern!r} last={last[:400]!r}")


def install(host: str) -> None:
    base = latest_manifest(host)
    client = connect(host)
    try:
        check_identity(client, base)
        now = snapshot(client)
        check_outside(base, now, "BASELINE_DRIFT")
        present = sorted(set(module_state(now)) - {DATA_DIR})
        if present:
            raise SystemExit(f"TARGET_EXISTS {present}：已经装过就用 upgrade；是残留就先 uninstall")
        if " /mnt/mmcblk0p6 ext4 " not in text(client, "cat /proc/mounts"):
            raise SystemExit("DATA_MOUNT_MISSING /mnt/mmcblk0p6")
        free_kb = int(text(client, "df -Pk /mnt/mmcblk0p6 | tail -1").split()[3])
        if free_kb < 500 * 1024:
            raise SystemExit(f"DATA_DISK_LOW free_kb={free_kb}")
        save_health(client, host)
        files = deploy_files(True)
        for dst, data, mode in files:
            upload(client, data, dst, mode)
        run(client, "/etc/init.d/r3mini-traffic enable && /etc/init.d/r3mini-traffic start")
        print("INSTALLED files=" + ",".join(dst for dst, _, _ in files))
    finally:
        client.close()
    verify(host, wait_data=True)


def local_version() -> str:
    return re.search(r"const VERSION = '([0-9.]+)'", local_file(SCRIPT).decode())[1]


def verify(host: str, wait_data: bool = False, old_run_id: str | None = None, strict: bool = True) -> None:
    """status 必须来自本地这一版脚本；upgrade 时还要求 run_id 已换成新进程的，防止拿旧进程的状态判通过。"""
    base = latest_manifest(host)
    client = connect(host)
    try:
        fresh = rf"(?!{re.escape(old_run_id)} )" if old_run_id else ""
        st = wait_for(client, "/usr/sbin/r3mini-traffic status",
                      rf"STATUS_OK 版本 {re.escape(local_version())} pid \d+ run_id {fresh}[0-9a-f]{{8}} ", 60)
        print(st.strip())
        if wait_data:
            wait_for(client, f"ls {DATA_DIR}/*/*.tsv 2>/dev/null", r"\.tsv", 90)
        files = text(client, f"ls -l {DATA_DIR} {DATA_DIR}/*/ 2>&1", check=False)
        log = text(client, f"tail -n 5 {DATA_DIR}/r3mini-traffic.log", check=False)
        print("DATA_FILES\n" + files.strip())
        print("LOG_TAIL\n" + log.strip())
        svc = text(client, "/etc/init.d/r3mini-traffic status; /etc/init.d/r3mini-traffic enabled && echo ENABLED")
        if "running" not in svc or "ENABLED" not in svc:
            raise SystemExit("SERVICE_NOT_RUNNING_OR_NOT_ENABLED " + svc)
        now = snapshot(client)
        check_outside(base, now, "UNEXPECTED_CHANGES")
        bad = expect_installed(now)
        if bad:
            raise SystemExit("MODULE_NOT_AS_EXPECTED " + "; ".join(bad))
        print(f"SNAPSHOT_DIFF_OK outside_items={sum(1 for p in now if not is_module(p))} module={sorted(module_state(now))}")
        if luci_checks(client):
            raise SystemExit("LUCI_CHECK_FAILED")
        health_gate(client, host, "AFTER", strict)
        print(f"VERIFY_OK host={host}")
    finally:
        client.close()


def upgrade(host: str) -> None:
    """已安装时替换脚本、服务定义与 LuCI 文件（保留用户配置与数据），重启后按安装同一套标准验收。"""
    base = latest_manifest(host)
    client = connect(host)
    try:
        check_identity(client, base)
        now = snapshot(client)
        check_outside(base, now, "NOT_IN_INSTALLED_STATE")
        core = [dst for _, dst, _ in CORE_FILES] + [CONFIG_FILE[1]] + list(RC_LINKS)
        missing = [p for p in core if p not in now]
        if missing:
            raise SystemExit(f"NOT_IN_INSTALLED_STATE missing={missing}：没装过就用 install")
        old = text(client, "/usr/sbin/r3mini-traffic version", check=False).strip()
        m = re.search(r"run_id ([0-9a-f]{8})", text(client, "/usr/sbin/r3mini-traffic status", check=False))
        # 原有功能基线在升级前现取，而不是沿用安装时那份（OpenClash 期间重启过进程号就会不同）
        save_health(client, host)
        files = deploy_files(False)
        for dst, data, mode in files:
            upload(client, data, dst, mode)
        stale = leftovers(now, {dst for dst, _, _ in files})
        if stale:
            run(client, "rm -f " + " ".join(shlex.quote(p) for p in stale))
        run(client, "/etc/init.d/r3mini-traffic restart")
        print(f"UPGRADED from={old} to={text(client, '/usr/sbin/r3mini-traffic version').strip()} "
              f"files={','.join(dst for dst, _, _ in files)} removed_stale={stale}")
    finally:
        client.close()
    verify(host, old_run_id=m[1] if m else None)


def rollback(host: str) -> None:
    """恢复演练：把本模块的文件与开机链接恢复成最新备份里的样子（备份里没有的删掉），按备份时是否在运行决定启停。
    通过条件：整份快照（数据目录除外）与备份清单逐项相等，原有功能与改动前一致。数据目录与历史记录不动。"""
    base = latest_manifest(host)
    plain = win32crypt.CryptUnprotectData((BACKUP_DIR / base["archive"]).read_bytes(), None, None, None, 0)[1]
    if digest(plain) != base["archive_sha256"]:
        raise SystemExit(f"BACKUP_SHA256_MISMATCH expect={base['archive_sha256']} got={digest(plain)}")
    restore: dict[str, tuple] = {}
    with tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz") as tf:
        for member in tf.getmembers():
            path = "/" + member.name.lstrip("./")
            if path == DATA_DIR or not is_module(path):
                continue
            if member.issym():
                restore[path] = ("L", member.linkname)
            elif member.isfile():
                restore[path] = ("F", tf.extractfile(member).read(), f"{member.mode & 0o7777:o}")
    want_snap = {p: v for p, v in base["snapshot"].items() if p != DATA_DIR}
    missing = sorted(p for p in module_state(want_snap) if p not in restore)
    if missing:
        raise SystemExit(f"BACKUP_MODULE_MEMBER_MISSING {missing}")
    was_running = "r3mini-traffic:1" in base["metadata"].get("services", [])
    client = connect(host)
    try:
        check_identity(client, base)
        now = snapshot(client)
        check_outside(base, now, "NOT_ROLLBACKABLE")
        # 原有功能沿用最近一次 install/upgrade 前取的基线，不在回滚前重取：真出事时回滚前的状态本身就是坏的，
        # 拿它当基线会让仍然坏着的项通过、修好的项反而报差异。期间 OpenClash 自己重启过时进程号会报差异，人工核对即可
        m = re.search(r"run_id ([0-9a-f]{8})", text(client, "/usr/sbin/r3mini-traffic status", check=False))
        # 停掉后删掉旧进程留下的 status.json，等到的状态才一定来自恢复出来的那一版
        run(client, "[ -x /etc/init.d/r3mini-traffic ] && /etc/init.d/r3mini-traffic stop; "
                    "rm -f /var/run/r3mini-traffic/status.json; true")
        if not was_running:
            run(client, "rm -rf /var/run/r3mini-traffic")
        extra = sorted(p for p in module_state(now) if p != DATA_DIR and p not in restore)
        if extra:
            run(client, "rm -f " + " ".join(shlex.quote(p) for p in extra))
        for path, item in sorted(restore.items()):
            if item[0] == "F":
                upload(client, item[1], path, item[2])
            else:
                run(client, f"ln -sfn {shlex.quote(item[1])} {shlex.quote(path)}")
        if was_running:
            run(client, "/etc/init.d/r3mini-traffic start")
        after = {p: v for p, v in snapshot(client).items() if p != DATA_DIR}
        added, removed, changed = diff_snapshot(want_snap, after)
        if added or removed or changed:
            raise SystemExit(f"ROLLBACK_MISMATCH added={sorted(added)} removed={sorted(removed)} changed={sorted(changed)}")
        print(f"SNAPSHOT_EQUALS_BACKUP items={len(after)} backup={base['archive']} restored={sorted(restore)} "
              f"removed={extra}")
        if was_running and base.get("installed_version"):
            fresh = rf"(?!{re.escape(m[1])} )" if m else ""
            print(wait_for(client, "/usr/sbin/r3mini-traffic status",
                           rf"STATUS_OK 版本 {re.escape(base['installed_version'])} pid \d+ run_id {fresh}[0-9a-f]{{8}} ",
                           60).strip())
        elif run(client, "pgrep -f '[r]3mini-traffic run'", check=False)[0] == 0:
            raise SystemExit("PROCESS_STILL_RUNNING")
        if MENU[1] not in restore:
            gone = menu_node(text(client, "sh -s /nonexistent", data=LUCI_SCRIPT.encode(), timeout=60)) is None
            print(f"LUCI_MENU_REMOVED_{'OK' if gone else 'FAIL'}")
            if not gone:
                raise SystemExit("LUCI_MENU_STILL_PRESENT")
        health_gate(client, host, "AFTER_ROLLBACK")
        print(f"ROLLBACK_OK host={host} running={was_running} version={base.get('installed_version') or '-'}")
    finally:
        client.close()


def uninstall(host: str, purge: bool) -> None:
    base = latest_manifest(host)
    client = connect(host)
    try:
        now = snapshot(client)
        files = sorted(p for p in module_state(now) if p != DATA_DIR and p not in RC_LINKS)
        cmd = ("[ -x /etc/init.d/r3mini-traffic ] && { /etc/init.d/r3mini-traffic stop; "
               "/etc/init.d/r3mini-traffic disable; }; rm -f " + " ".join(shlex.quote(p) for p in files or ["/nonexistent"]) +
               " " + " ".join(RC_LINKS) + "; rm -rf /var/run/r3mini-traffic" + (f" {DATA_DIR}" if purge else "") + "; true")
        run(client, cmd)
        # [r] 让正则不匹配执行本命令的 shell 自身的命令行
        if run(client, "pgrep -f '[r]3mini-traffic run'", check=False)[0] == 0:
            raise SystemExit("PROCESS_STILL_RUNNING")
        after = snapshot(client)
        check_outside(base, after, "NOT_RESTORED")
        left = sorted(module_state(after))
        if left != ([] if purge else [DATA_DIR]) and left != []:
            raise SystemExit(f"NOT_RESTORED module_left={left}")
        gone = menu_node(text(client, "sh -s /nonexistent", data=LUCI_SCRIPT.encode(), timeout=60)) is None
        if not gone:
            raise SystemExit("LUCI_MENU_STILL_PRESENT")
        print(f"SNAPSHOT_RESTORED outside_items={sum(1 for p in after if not is_module(p))} removed={files} leftover={left}")
        health_gate(client, host, "AFTER_UNINSTALL")
        print(f"UNINSTALL_OK host={host} purge={purge}")
    finally:
        client.close()


def check_backup(path: str, extract: str | None) -> None:
    """在内存里解密备份并核对清单；--extract DIR 时才把明文 tar.gz 写到 DIR（明文含 /etc/shadow 与主机密钥）。"""
    src = pathlib.Path(path)
    manifest = json.loads(pathlib.Path(str(src).replace(".tar.gz.dpapi", ".manifest.json")).read_text(encoding="utf-8"))
    plain = win32crypt.CryptUnprotectData(src.read_bytes(), None, None, None, 0)[1]
    if digest(plain) != manifest["archive_sha256"]:
        raise SystemExit(f"BACKUP_SHA256_MISMATCH expect={manifest['archive_sha256']} got={digest(plain)}")
    with tarfile.open(fileobj=io.BytesIO(plain), mode="r:gz") as tf:
        entries = len(tf.getmembers())
    if entries != manifest["archive_entries"]:
        raise SystemExit(f"BACKUP_ENTRIES_MISMATCH expect={manifest['archive_entries']} got={entries}")
    print(f"BACKUP_CHECK_OK host={manifest['host']} stamp={manifest['stamp']} entries={entries} sha256={digest(plain)}")
    if extract:
        out = pathlib.Path(extract) / src.name.replace(".dpapi", "")
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("xb") as stream:
            stream.write(plain)
        print(f"PLAINTEXT_WRITTEN={out}  # 含 /etc/shadow 与主机密钥，用完删除")


def remote_cli(host: str, args: list[str]) -> None:
    client = connect(host)
    try:
        rc, out, err = run(client, "/usr/sbin/r3mini-traffic " + " ".join(shlex.quote(a) for a in args),
                           timeout=120, check=False)
        print(out.decode("utf-8", "replace") + err.decode("utf-8", "replace"), end="")
        if rc:
            raise SystemExit(rc)
    finally:
        client.close()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    hosts = [a for a in rest if not a.startswith("--")]
    if cmd == "backup":
        for h in hosts:
            backup(h)
    elif cmd == "selftest":
        selftest(hosts[0])
    elif cmd == "dryrun":
        dryrun(hosts[0], int(hosts[1]) if len(hosts) > 1 else 60)
    elif cmd == "install":
        for h in hosts:
            install(h)
    elif cmd == "verify":
        for h in hosts:
            verify(h, strict=False)
    elif cmd == "upgrade":
        for h in hosts:
            upgrade(h)
    elif cmd == "rollback":
        for h in hosts:
            rollback(h)
    elif cmd == "uninstall":
        for h in hosts:
            uninstall(h, "--purge-data" in rest)
    elif cmd in ("status", "report"):
        remote_cli(rest[0], [cmd] + rest[1:])
    elif cmd == "check-backup":
        check_backup(rest[0], rest[rest.index("--extract") + 1] if "--extract" in rest else None)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main(sys.argv[1:]))
