'use strict';
// 上网出口模块的日志：唯一的写入口（r3mini-hotspot-web、看门狗都经它写）。
//
//   ucode log.uc write <run_id> <level> <event> <msg> [k=v ...]   追加一行
//   ucode log.uc prune                                            按保留期清理轮转出的旧文件
//   ucode log.uc path                                             打印日志文件的绝对路径和是否持久
//
// 行格式：<ts> <level> <run_id> <event> <msg> [k=v ...]
//   ts 为 ISO8601 带毫秒和时区；值含空格或引号时加双引号；单个值超过 2048 字节截断并加 truncated=true bytes=<n>。
// 位置：数据分区 /mnt/mmcblk0p6 挂着时写 /mnt/mmcblk0p6/r3mini-hotspot/hotspot.log（重启不丢）；
//   没挂上时写 /tmp/r3mini-hotspot-log/hotspot.log，并在每行加 persist=false。
// 轮转：超过 256 KB 时 hotspot.log → .1 → .2 → .3，最多 4 份约 1 MB；轮转出的文件超过 14 天删除。
// 测试钩子：R3HS_LOG_DIR（日志目录）、R3HS_LOG_MAX（单文件字节上限）。
// 密码、密钥一律不要传进来；这里不做内容识别。

import { open, stat, rename, unlink, mkdir, readfile, access } from 'fs';

const MAX_VALUE = 2048;
const KEEP = 3;
const KEEP_DAYS = 14;

function log_dir() {
	const forced = getenv('R3HS_LOG_DIR');
	if (forced)
		return [forced, true];
	const mounts = readfile('/proc/mounts') ?? '';
	if (match(mounts, /\n?[^ ]+ \/mnt\/mmcblk0p6 /))
		return ['/mnt/mmcblk0p6/r3mini-hotspot', true];
	return ['/tmp/r3mini-hotspot-log', false];
}

function pad(n, w) {
	let s = `${n}`;
	while (length(s) < w)
		s = '0' + s;
	return s;
}

function timestamp() {
	const c = clock();
	const t = localtime(c[0]);
	const g = gmtime(c[0]);
	// 本地时区偏移：本地时间与 UTC 的差。
	let off = (timegm(t) - timegm(g)) / 60;
	const sign = off < 0 ? '-' : '+';
	off = off < 0 ? -off : off;
	return sprintf('%04d-%s-%sT%s:%s:%s.%s%s%s:%s',
		t.year, pad(t.mon, 2), pad(t.mday, 2), pad(t.hour, 2), pad(t.min, 2), pad(t.sec, 2),
		pad(int(c[1] / 1000000), 3), sign, pad(int(off / 60), 2), pad(off % 60, 2));
}

function clean(s) {
	// 一行一条：换行、回车、制表符都换成空格。
	return replace(`${s}`, /[\r\n\t]+/g, ' ');
}

function kv(arg) {
	const i = index(arg, '=');
	if (i < 1)
		return clean(arg);
	const key = substr(arg, 0, i);
	let val = clean(substr(arg, i + 1));
	let extra = '';
	if (length(val) > MAX_VALUE) {
		extra = sprintf(' truncated=true bytes=%d', length(val));
		val = substr(val, 0, MAX_VALUE);
	}
	if (val == '' || match(val, /[ "=]/))
		val = '"' + replace(val, /"/g, '\\"') + '"';
	return key + '=' + val + extra;
}

function rotate(dir, max) {
	const file = dir + '/hotspot.log';
	const st = stat(file);
	if (!st || st.size < max)
		return false;
	unlink(dir + '/hotspot.log.' + KEEP);
	for (let i = KEEP - 1; i >= 1; i--)
		rename(dir + '/hotspot.log.' + i, dir + '/hotspot.log.' + (i + 1));
	rename(file, dir + '/hotspot.log.1');
	return true;
}

function prune(dir) {
	const now = time();
	let removed = 0;
	for (let i = 1; i <= KEEP; i++) {
		const f = dir + '/hotspot.log.' + i;
		const st = stat(f);
		if (st && now - st.mtime > KEEP_DAYS * 86400 && unlink(f))
			removed++;
	}
	return removed;
}

function append(dir, persist, line) {
	if (!access(dir))
		mkdir(dir, 0o700);
	const f = open(dir + '/hotspot.log', 'a', 0o600);
	if (!f)
		return false;
	f.write(line + (persist ? '' : ' persist=false') + '\n');
	f.close();
	return true;
}

const args = ARGV;
const mode = args[0];
const where = log_dir();
const dir = where[0], persist = where[1];
const max = +(getenv('R3HS_LOG_MAX') ?? 0) || 262144;

if (mode == 'path') {
	print(dir + '/hotspot.log ' + (persist ? 'persist=true' : 'persist=false') + '\n');
} else if (mode == 'prune') {
	const n = prune(dir);
	if (n > 0)
		append(dir, persist, join(' ', [timestamp(), 'INFO', 'log', 'log.prune', '删除超过保留期的旧日志', 'removed=' + n, 'keep_days=' + KEEP_DAYS]));
} else if (mode == 'write' && length(args) >= 5) {
	const run_id = args[1], level = args[2], event = args[3], msg = args[4];
	if (rotate(dir, max)) {
		append(dir, persist, join(' ', [timestamp(), 'INFO', 'log', 'log.rotate', '日志超过上限，已轮转', 'max_bytes=' + max, 'keep=' + KEEP]));
		prune(dir);
	}
	let parts = [timestamp(), uc(level), clean(run_id) || '-', clean(event), kv('msg=' + msg)];
	// msg 也按 k=v 规则加引号，但去掉键名，保持「人话短句」在第五列。
	parts[4] = substr(parts[4], 4);
	for (let i = 5; i < length(args); i++)
		push(parts, kv(args[i]));
	if (!append(dir, persist, join(' ', parts)))
		exit(1);
} else {
	warn('用法: ucode log.uc write <run_id> <level> <event> <msg> [k=v ...] | prune | path\n');
	exit(2);
}
