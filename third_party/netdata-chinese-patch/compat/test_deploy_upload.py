from pathlib import Path
import base64
import re

from deploy_router import encoded_chunks, validated_backup_path


payload = Path(__file__).with_name("netdata-zh-cn.js").read_bytes().replace(b"\r\n", b"\n")
chunks = encoded_chunks(payload)
assert len(chunks) > 1
assert max(map(len, chunks)) <= 240
assert b"".join(base64.b64decode(chunk) for chunk in chunks) == payload
assert validated_backup_path("/root/netdata-zh-cn-backup-20260718-181613") == "/root/netdata-zh-cn-backup-20260718-181613"
try:
    validated_backup_path("/root/netdata-zh-cn-backup-x;reboot")
except ValueError as error:
    assert str(error) == "invalid_rollback_backup"
else:
    raise AssertionError("unsafe_rollback_path_accepted")
deploy = Path(__file__).with_name("deploy-openwrt.sh").read_text(encoding="utf-8")
assert "luci_view=/www/luci-static/resources/view/netdata.js" in deploy
assert "luci_iframe_cachebuster_failed" in deploy
assert "cp -p \"$luci_view\" \"$backup/luci-netdata.js\"" in deploy
fixture = "return E('iframe', { src: 'http://192.168.0.242:19999' });\n"
cachebuster = re.sub(r"(:19999)(\?v=[^\"']*)?([\"'])", r"\1?v=abc123def456\3", fixture)
assert ":19999?v=abc123def456'" in cachebuster
assert ":19999?v=abc123def456'" in re.sub(r"(:19999)(\?v=[^\"']*)?([\"'])", r"\1?v=abc123def456\3", fixture.replace(":19999'", ":19999?v=old'"))
print("CHUNKED_UPLOAD=PASS")
