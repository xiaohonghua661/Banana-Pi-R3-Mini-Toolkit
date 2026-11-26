"""部署器的离线测试：身份检查。不连设备，不读私密文档。

    python socks5-gateway/test_manage.py
"""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("socks5_manage", Path(__file__).with_name("manage.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

R3MINI, PI5 = "bananapi,bpi-r3-mini", "raspberrypi,5-model-b"
HOST = "192.0.2.1"


def fake_device(board, proto, ipaddr, br_lan):
    """代替 run()，只认身份检查用到的命令。uci 读不到的项、不存在的 br-lan 和设备上一样退出码 1；
    br-lan 那几行照树莓派上 `ip -4 -o addr show dev br-lan` 的真实输出。"""
    lines = "".join(f"4: br-lan    inet {a}/24 brd 192.0.2.255 scope global br-lan\\       "
                    "valid_lft forever preferred_lft forever\n" for a in br_lan or ())
    outputs = {"ubus call system board": (0, json.dumps({"board_name": board})),
               "uci -q get network.lan.proto": (0, proto) if proto else (1, ""),
               "uci -q get network.lan.ipaddr": (0, ipaddr) if ipaddr else (1, ""),
               "ip -4 -o addr show dev br-lan": (0, lines) if br_lan is not None else (1, "")}

    def run(client, command, *, data=None, timeout=90, check=True):
        code, out = outputs[command]  # 别的命令一律 KeyError：身份不符时不该走到后面
        if check and code:
            m.fail("REMOTE_COMMAND_FAILED: " + command)
        return code, (out + "\n").encode(), b""
    return run


class IdentityTests(unittest.TestCase):
    def test_accepts_static_r3mini_and_dhcp_or_static_pi(self):
        for board, proto, ipaddr, br_lan in ((R3MINI, "static", HOST, [HOST]),
                                             (PI5, "dhcp", None, ["192.0.2.9", HOST]),
                                             (PI5, "static", HOST, [HOST]),
                                             (R3MINI, None, HOST, [HOST])):
            with self.subTest(board=board, proto=proto), \
                    mock.patch.object(m, "run", side_effect=fake_device(board, proto, ipaddr, br_lan)):
                self.assertIsNone(m.identity(None, HOST))

    def test_rejects_wrong_board_or_address(self):
        cases = (("unknown board", "bananapi,bpi-r3mini", "static", HOST, [HOST]),
                 ("dhcp, host not on br-lan", PI5, "dhcp", None, ["192.0.2.9"]),
                 ("dhcp, host is only a prefix", PI5, "dhcp", None, ["192.0.2.10"]),
                 ("dhcp, no br-lan", PI5, "dhcp", None, None),
                 ("dhcp ignores a stale lan.ipaddr", PI5, "dhcp", HOST, ["192.0.2.9"]),
                 ("static, lan.ipaddr unset", R3MINI, "static", None, [HOST]),
                 ("static, other lan.ipaddr", R3MINI, "static", "192.0.2.9", [HOST]),
                 ("static ignores br-lan", PI5, "static", "192.0.2.9", [HOST]))
        for name, board, proto, ipaddr, br_lan in cases:
            with self.subTest(name), mock.patch.object(m, "run", side_effect=fake_device(board, proto, ipaddr, br_lan)):
                with self.assertRaises(SystemExit) as caught:
                    m.identity(None, HOST)
                self.assertEqual(caught.exception.code, "ROUTER_IDENTITY_MISMATCH")

    def test_every_command_checks_identity_before_anything_else(self):
        args = mock.Mock(backup=m.STATE + "/install-backup-20261127T012730")
        for command in (m.install, m.verify, m.rollback):
            with self.subTest(command.__name__), \
                    mock.patch.object(m, "run", side_effect=fake_device(PI5, "dhcp", None, ["192.0.2.9"])):
                with self.assertRaises(SystemExit) as caught:
                    command(None, HOST, args)
                self.assertEqual(caught.exception.code, "ROUTER_IDENTITY_MISMATCH")


if __name__ == "__main__":
    unittest.main(verbosity=2)
