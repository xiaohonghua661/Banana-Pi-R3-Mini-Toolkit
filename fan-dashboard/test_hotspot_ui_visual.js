'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const root = __dirname;
const source = fs.readFileSync(path.join(root, 'router', 'www', 'luci-static', 'resources', 'view', 'network', 'r3mini-hotspot.js'), 'utf8');
const output = process.env.R3MINI_UI_TEST_OUTPUT || 'C:/tmp';
const browserExecutable = process.env.R3MINI_BROWSER || [
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
].find(candidate => fs.existsSync(candidate));

function status(overrides = {}) {
  return Object.assign({
    configured: true,
    enabled: true,
    key_configured: true,
    ssid: 'Phone-5G',
    wwan_up: true,
    wired_wan_up: true,
    cellular_up: true,
    wwan_ip: '192.0.2.12',
    channel: '157',
    target_channel: '157',
    egress_kind: 'hotspot',
    egress_label: '手机热点 Wi-Fi',
    egress_iface: 'wwan',
    egress_device: 'phy1-sta0',
    egress_ip: '192.0.2.12',
    preferred_egress: 'auto',
    check_interval: 20,
    failure_limit: 2,
    cooldown: 60,
    probe_status: 'ok',
    probe_reason: '当前出口延迟最低',
    probe_target: 'Claude + Anthropic',
    probe_age: 1,
    probe_stale: false,
    probe_wan_ms: '83',
    probe_cellular_ms: '121',
    probe_hotspot_ms: '66',
    event_elapsed_ms: 42,
    event_action: 'ifup',
    event_interface: 'wwan',
    event_age: 1
  }, overrides);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

(async () => {
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: browserExecutable });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('pageerror', error => errors.push(error.message));
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"><style>body{margin:0;background:#eef2ef}#view{padding:20px}</style></head><body><div id="view"></div></body></html>');
  await page.evaluate(({ moduleSource, initial }) => {
    window.__status = initial;
    window.__rpcDelay = 0;
    window.__statusRpcActive = 0;
    window.__statusRpcMax = 0;
    function result(value) { return { code: 0, stdout: JSON.stringify(value), stderr: '' }; }
    const fsStub = {
      exec(_helper, args) {
        const isStatus = args[0] === 'status';
        if (isStatus) {
          window.__statusRpcActive++;
          window.__statusRpcMax = Math.max(window.__statusRpcMax, window.__statusRpcActive);
        }
        return new Promise(resolve => setTimeout(() => {
          if (args[0] === 'prefer') {
            const kind = args[1];
            const route = kind === 'wan'
              ? { egress_kind: 'wan', egress_label: '有线 WAN', egress_iface: 'wan', egress_device: 'eth1', egress_ip: '198.51.100.30' }
              : kind === 'cellular'
                ? { egress_kind: 'cellular', egress_label: '蜂窝网络 5G', egress_iface: 'cellular', egress_device: 'wwan0', egress_ip: '203.0.113.8' }
                : kind === 'hotspot'
                  ? { egress_kind: 'hotspot', egress_label: '手机热点 Wi-Fi', egress_iface: 'wwan', egress_device: 'phy1-sta0', egress_ip: '192.0.2.12' }
                  : {};
            window.__status = Object.assign({}, window.__status, route, { preferred_egress: kind });
          }
          if (isStatus) window.__statusRpcActive--;
          resolve(result(window.__status));
        }, window.__rpcDelay));
      },
      write() { return Promise.resolve(); },
      remove() { return Promise.resolve(); }
    };
    const uiStub = { addNotification() {} };
    function E(tag, attrs, children) {
      const node = document.createElement(tag);
      Object.entries(attrs || {}).forEach(([key, value]) => key === 'class' ? node.className = value : node.setAttribute(key, value));
      const values = Array.isArray(children) ? children : children == null ? [] : [children];
      values.forEach(value => node.append(value && value.nodeType ? value : document.createTextNode(String(value))));
      return node;
    }
    const viewStub = { extend(value) { return value; } };
    window.__module = new Function('view', 'fs', 'ui', 'E', 'TextEncoder', moduleSource)(viewStub, fsStub, uiStub, E, TextEncoder);
    document.querySelector('#view').append(window.__module.render(window.__status));
  }, { moduleSource: source, initial: status() });
  await page.waitForSelector('.r3hotspot-app');

  const desktop = await page.evaluate(() => {
    const title = document.querySelector('.rh-title');
    const routes = Array.from(document.querySelectorAll('.rh-route-detail')).map(node => node.textContent);
    const buttons = Array.from(document.querySelectorAll('.rh-prefer'));
    return {
      title: title.textContent,
      titleColor: getComputedStyle(title).color,
      titleShadow: getComputedStyle(title).textShadow,
      headerAfter: getComputedStyle(document.querySelector('.rh-head'), '::after').content,
      overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      routes,
      enabledButtons: buttons.filter(button => !button.disabled).length,
      selected: buttons.find(button => button.classList.contains('selected')).dataset.prefer
    };
  });
  assert(desktop.title === '网络接力控制台', 'title text mismatch');
  assert(desktop.titleColor === 'rgb(14, 73, 56)', `title contrast color mismatch: ${desktop.titleColor}`);
  assert(desktop.titleShadow === 'none', 'title still has inherited white shadow');
  assert(desktop.headerAfter === 'none', 'header white overlay still present');
  assert(!desktop.overflow, 'desktop horizontal overflow');
  assert(desktop.enabledButtons === 4, 'all-online manual choices are not enabled');
  assert(desktop.selected === 'auto', 'automatic preference is not selected');
  assert(desktop.routes.every(text => /\d+ ms/.test(text)), 'route scores are not visible');
  await page.screenshot({ path: path.join(output, 'r3mini-egress-ui-desktop.png'), fullPage: true });

  await page.evaluate(() => { window.__rpcDelay = 140; });
  const switchStart = Date.now();
  await page.click('[data-prefer="wan"]');
  const immediate = await page.textContent('#rh-egress');
  assert(immediate.includes('正在切换到有线 WAN'), 'manual switch has no immediate feedback');
  await page.waitForFunction(() => document.querySelector('[data-prefer="wan"]').classList.contains('selected'));
  const switchElapsed = Date.now() - switchStart;
  assert(switchElapsed < 500, `manual switch feedback too slow: ${switchElapsed}ms`);

  const disconnectElapsed = await page.evaluate(async next => {
    window.__module.startBurst();
    await new Promise(resolve => setTimeout(resolve, 15));
    const started = performance.now();
    window.__status = next;
    while (!document.querySelector('#rh-health span').textContent.includes('正在重连')) {
      await new Promise(resolve => setTimeout(resolve, 5));
      if (performance.now() - started > 500) throw new Error('disconnect state not discovered');
    }
    return performance.now() - started;
  }, status({
    wwan_up: false,
    egress_kind: 'wan',
    egress_label: '有线 WAN',
    egress_iface: 'wan',
    egress_device: 'eth1',
    egress_ip: '198.51.100.30',
    preferred_egress: 'auto',
    event_elapsed_ms: 37,
    event_action: 'ifdown',
    event_interface: 'wwan',
    probe_hotspot_ms: ''
  }));
  assert(disconnectElapsed < 250, `burst disconnect discovery too slow: ${disconnectElapsed.toFixed(1)}ms`);
  const stateAfterDisconnect = await page.evaluate(() => ({
    health: document.querySelector('#rh-health span').textContent,
    event: document.querySelector('#rh-event').textContent,
    maxRpc: window.__statusRpcMax,
    autoDisabled: document.querySelector('[data-prefer="auto"]').disabled,
    wanDisabled: document.querySelector('[data-prefer="wan"]').disabled,
    hotspotDisabled: document.querySelector('[data-prefer="hotspot"]').disabled
  }));
  assert(stateAfterDisconnect.health.includes('正在重连'), 'disconnect does not show reconnecting state');
  assert(stateAfterDisconnect.event.includes('37 ms'), 'event milliseconds are not visible');
  assert(stateAfterDisconnect.maxRpc === 1, `overlapping status RPCs detected: ${stateAfterDisconnect.maxRpc}`);
  assert(!stateAfterDisconnect.autoDisabled && !stateAfterDisconnect.wanDisabled, 'online fallback choices are disabled');
  assert(stateAfterDisconnect.hotspotDisabled, 'offline manual route is still selectable');

  await page.setViewportSize({ width: 390, height: 844 });
  const mobile = await page.evaluate(() => ({
    overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
    offenders: Array.from(document.querySelectorAll('body *')).map(node => {
      const rect = node.getBoundingClientRect();
      return { name: node.id || node.className || node.tagName, left: rect.left, right: rect.right, width: rect.width };
    }).filter(item => item.left < -0.5 || item.right > document.documentElement.clientWidth + 0.5).slice(0, 8),
    buttonHeight: Math.min(...Array.from(document.querySelectorAll('.rh-prefer')).map(node => node.getBoundingClientRect().height))
  }));
  await page.screenshot({ path: path.join(output, 'r3mini-egress-ui-mobile.png'), fullPage: true });
  assert(!mobile.overflow, `mobile horizontal overflow: ${JSON.stringify(mobile)}`);
  assert(mobile.buttonHeight >= 44, `mobile target below 44px: ${mobile.buttonHeight}`);
  assert(errors.length === 0, `browser errors: ${errors.join(' | ')}`);

  console.log('TITLE_CONTRAST=PASS');
  console.log('ALL_ONLINE_MANUAL_CHOICES=PASS');
  console.log(`MANUAL_SWITCH_FEEDBACK_MS=${switchElapsed}`);
  console.log(`BURST_DISCONNECT_DISCOVERY_MS=${disconnectElapsed.toFixed(1)}`);
  console.log('SINGLE_INFLIGHT_RPC=PASS');
  console.log('DESKTOP_OVERFLOW=false');
  console.log('MOBILE_OVERFLOW=false');
  console.log(`MOBILE_BUTTON_MIN_HEIGHT=${mobile.buttonHeight}`);
  console.log('CONSOLE_ERRORS=0');
  console.log(`DESKTOP_SCREENSHOT=${path.join(output, 'r3mini-egress-ui-desktop.png')}`);
  console.log(`MOBILE_SCREENSHOT=${path.join(output, 'r3mini-egress-ui-mobile.png')}`);
  await browser.close();
})().catch(error => {
  console.error(error.stack || error);
  process.exit(1);
});
