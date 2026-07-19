/*
 * Netdata v1.38.1 Simplified Chinese overlay.
 * Translation terms are adapted from DX-Kevin/Netdata-chinese-patch,
 * but retain the upstream React dashboard and use Mainland Simplified Chinese.
 */
(() => {
  'use strict';

  const translations = new Map([
    ['System Overview', '系统概览'],
    ['Overview of the key system metrics.', '关键系统指标概览。'],
    ['Home', '主页'], ['Node View', '节点视图'], ['Overview', '概览'], ['Nodes', '节点'],
    ['Dashboards', '仪表盘'], ['Alerts', '告警'], ['Anomalies', '异常'], ['Pricing', '价格'], ['Privacy', '隐私'],
    ['Connection to Cloud', '连接 Netdata Cloud'], ['Paused', '已暂停'], ['Sign in', '登录'],
    ['CPU', 'CPU'], ['Disk Read', '磁盘读取'], ['Disk Write', '磁盘写入'],
    ['Net Inbound', '网络入站'], ['Net Outbound', '网络出站'], ['Used RAM', '已用内存'],
    ['Applications Monitoring', '应用监控'],
    ['cpu', 'CPU'], ['load', '负载'], ['disk', '磁盘'], ['ram', '内存'], ['network', '网络'],
    ['processes', '进程'], ['idlejitter', '空闲抖动'], ['interrupts', '中断'], ['softirqs', '软中断'],
    ['softnet', '网络软中断'], ['entropy', '熵'], ['uptime', '运行时间'],
    ['clock synchronization', '时钟同步'], ['ipc semaphores', '进程间信号量'],
    ['CPUs', 'CPU'], ['Memory', '内存'], ['Disks', '磁盘'], ['Networking Stack', '网络协议栈'],
    ['IPv4 Networking', 'IPv4 网络'], ['IPv6 Networking', 'IPv6 网络'],
    ['Network Interfaces', '网络接口'], ['Firewall (netfilter)', '防火墙（netfilter）'],
    ['Netdata Monitoring', 'Netdata 监控'], ['Add more charts', '添加更多图表'],
    ['Add more alarms', '添加更多告警'],
    ['Discover the free benefits of Netdata Cloud:', '探索 Netdata Cloud 的免费功能：'],
    ['Total CPU utilization (all cores).', '总 CPU 利用率（所有核心）。'],
    ['100% here means there is no CPU idle time at all.', '此处 100% 表示 CPU 没有空闲时间。'],
    ['You can get per core usage at the CPUs section and per application usage at the Applications Monitoring section.', '可在“CPU”部分查看各核心用量，在“应用监控”部分查看各应用用量。'],
    ['You can get per core usage at the', '可在“'], ['section and per application usage at the', '”部分查看各核心用量，并可在“'], ['section.', '”部分查看各应用用量。'],
    ['Keep an eye on iowait', '关注 iowait'],
    ['Keep an eye on', '关注'],
    ['If it is constantly high, your disks are a bottleneck and they slow your system down.', '若该值持续偏高，磁盘可能成为瓶颈并拖慢系统。'],
    ['If it is constantly high,', '若其持续偏高，'], ['your disks are a bottleneck and they slow your system down.', '磁盘可能成为瓶颈并拖慢系统。'],
    ['An important metric worth monitoring, is softirq', '另一个值得关注的指标是 softirq'],
    ['An important metric worth monitoring, is', '另一个值得关注的指标是'],
    ['A constantly high percentage of softirq may indicate network driver issues.', 'softirq 占比持续偏高可能表示网络驱动存在问题。'],
    ['A constantly high percentage of', '持续偏高的'], ['may indicate network driver issues.', '可能表示网络驱动存在问题。'],
    ['The individual metrics can be found in the', '各项指标详见'], ['kernel documentation.', '内核文档。'], ['kernel documentation', '内核文档'],
    ['Current system load, i.e. the number of processes using CPU or waiting for system resources (usually CPU and disk).', '当前系统负载，即正在使用 CPU 或等待系统资源（通常是 CPU 和磁盘）的进程数。'],
    ['The 3 metrics refer to 1, 5 and 15 minute averages.', '这 3 项指标分别是 1、5 和 15 分钟平均值。'],
    ['The system calculates this once every 5 seconds.', '系统每 5 秒计算一次。'],
    ['For more information check', '更多信息请查看'], ['this wikipedia article.', '这篇维基百科文章。'], ['this wikipedia article', '这篇维基百科文章'],
    ['Total Disk I/O, for all physical disks.', '所有物理磁盘的总磁盘 I/O。'],
    ['Total CPU utilization (system.cpu)', '总 CPU 利用率（system.cpu）'],
    ['System Load Average (system.load)', '系统平均负载（system.load）'],
    ['Total Disk I/O (system.io)', '总磁盘 I/O（system.io）'],
    ['percentage', '百分比'], ['softirq', '软中断'], ['irq', '硬中断'], ['user', '用户态'],
    ['system', '内核态'], ['nice', '低优先级'], ['iowait', 'I/O 等待'],
    ['Physical are all the disks that are listed in `/sys/block`, but do not exist in `/sys/devices/virtual/block`.', '物理磁盘是列于 `/sys/block`、但不位于 `/sys/devices/virtual/block` 的所有磁盘。'],
    ['You can get detailed information about each disk at the', '可在“磁盘”部分查看每块磁盘的详细信息，'],
    ['section and per application Disk usage at the', '并在“应用监控”部分查看各应用的磁盘用量。'],
    ['Get more history by', '可通过'], ["configuring Netdata's history", '配置 Netdata 的历史记录'],
    ['or switching to the database engine.', '或切换到数据库引擎，以获取更多历史数据。'],
    ['Want to extend your history of real-time metrics?', '想延长实时指标的历史记录？'], ['or use the', '或者使用'],
    ['Every 2 seconds, Netdata collects', 'Netdata 每 2 秒采集'], ['metrics on', '项指标，主机：'],
    ['presents them in', '以'], ['charts, and monitors them with', '张图表展示，并监控'], ['alarms.', '条告警。'],
    ['Do you like Netdata?', '喜欢 Netdata 吗？'], ['Give us a star!', '请给我们点个 Star！'],
    ['And share the word!', '也欢迎分享给更多人！'],
    ['Settings', '设置'], ['Close', '关闭'], ['Cancel', '取消'], ['Save', '保存'],
    ['Performance', '性能'], ['Synchronization', '同步'], ['Visual', '显示'], ['Locale', '区域设置'],
    ['Download', '下载'], ['Upload', '上传'], ['Update Check', '检查更新'], ['Check Now', '立即检查'],
    ['Active', '活动'], ['All', '全部'], ['Log', '日志'], ['Loading...', '加载中…']
  ]);

  const attributes = ['aria-label', 'placeholder', 'title'];
  const externalLabels = new Set([
    'Connection to Cloud', 'Connect Netdata Cloud', 'Sign in', 'Pricing', 'Privacy',
    'Discover the free benefits of Netdata Cloud:', '连接 Netdata Cloud', '登录', '价格', '隐私',
    '探索 Netdata Cloud 的免费功能：'
  ]);
  const externalTextStarts = ['Do you like Netdata?', 'And share the word!', '喜欢 Netdata 吗？', '也欢迎分享给更多人！'];

  function translateText(text) {
    const trimmed = text.trim();
    const metrics = trimmed.match(/^Every 2 seconds, Netdata collects ([\d,]+) metrics on (.+?), presents them in ([\d,]+) charts, and monitors them with (\d+) alarms\.$/);
    if (metrics) return text.replace(trimmed, `Netdata 每 2 秒在 ${metrics[2]} 上采集 ${metrics[1]} 项指标，以 ${metrics[3]} 张图表展示，并监控 ${metrics[4]} 条告警。`);
    const replacement = translations.get(trimmed);
    let translated = replacement ? text.replace(trimmed, replacement) : text;
    translations.forEach((value, key) => {
      if (key.includes(' ') || key.length > 20 || key === 'section.' || key === 'alarms.') translated = translated.replaceAll(key, value);
    });
    return translated
      .replace(/(\d+)min\b/g, '$1 分钟')
      .replace(/(\d+) alarms\./g, '$1 条告警。');
  }

  function translateAttributes(element) {
    attributes.forEach((name) => {
      if (element.hasAttribute(name)) {
        const value = element.getAttribute(name);
        const translated = translateText(value);
        if (translated !== value) element.setAttribute(name, translated);
      }
    });
  }

  function translateElement(element) {
    if (element.nodeType === Node.TEXT_NODE) {
      const translated = translateText(element.nodeValue);
      if (translated !== element.nodeValue) element.nodeValue = translated;
      return;
    }
    if (element.nodeType !== Node.ELEMENT_NODE) return;
    translateAttributes(element);
    element.querySelectorAll('[aria-label], [placeholder], [title]').forEach(translateAttributes);
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) translateElement(node);
  }

  function translate(root) {
    translateElement(root);
    hideExternalUi(root);
  }

  function hideExternalUi(root) {
    if (root.nodeType !== Node.ELEMENT_NODE) return;
    root.querySelectorAll('a, button, [role="button"], li, p, div, span').forEach((element) => {
      const text = element.textContent.trim();
      if (externalLabels.has(text) || externalTextStarts.some((prefix) => text.startsWith(prefix))) {
        element.style.display = 'none';
        element.setAttribute('aria-hidden', 'true');
      }
    });
  }

  function start() {
    document.documentElement.lang = 'zh-CN';
    document.title = 'Netdata 仪表盘';
    const style = document.createElement('style');
    style.textContent = 'a[href*="netdata.cloud"],a[href*="my-netdata.io"],a[href*="github.com/netdata"],a[href*="twitter.com"],a[href*="facebook.com"]{display:none!important}';
    document.head.appendChild(style);
    translate(document.body);
    new MutationObserver((changes) => {
      changes.forEach((change) => {
        if (change.type === 'characterData') translate(change.target);
        else change.addedNodes.forEach((node) => translate(node));
      });
    }).observe(document.body, { childList: true, characterData: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
