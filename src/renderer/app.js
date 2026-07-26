/**
 * 渲染层：UI 事件绑定 + 步骤/进度/日志渲染。
 */
'use strict';

const api = window.installerAPI;

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const els = {
  btnMin: $('#btn-min'),
  btnClose: $('#btn-close'),
  btnStart: $('#btn-start'),
  btnCancel: $('#btn-cancel'),
  btnDetect: $('#btn-detect'),
  btnVerify: $('#btn-verify'),
  btnCCSwitch: $('#btn-ccswitch'),
  btnCopyLog: $('#btn-copy-log'),
  btnClearLog: $('#btn-clear-log'),
  btnOpenLog: $('#btn-open-log'),
  optGit: $('#opt-git'),
  optGitHint: $('#opt-git-hint'),
  progressTitle: $('#progress-title'),
  progressPercent: $('#progress-percent'),
  progressFill: $('#progress-fill'),
  progressDetail: $('#progress-detail'),
  log: $('#log'),
};

let mainInstallBusy = false;
let ccSwitchBusy = false;
let ccSwitchInstalled = false;

const ccSwitchLabel = els.btnCCSwitch.textContent;

function clearElement(element) {
  while (element.firstChild) element.removeChild(element.firstChild);
}

function syncOperationButtons() {
  els.btnStart.disabled = mainInstallBusy || ccSwitchBusy;
  const disableCCSwitch = mainInstallBusy || ccSwitchBusy || ccSwitchInstalled;
  els.btnCCSwitch.disabled = disableCCSwitch;
}

// ── 标题栏 ──
els.btnMin.addEventListener('click', () => api.minimize());
els.btnClose.addEventListener('click', () => api.quit());

// ── 关于弹层 ──
const aboutMask = document.getElementById('about-mask');
const btnAbout = document.getElementById('btn-about');
const btnAboutClose = document.getElementById('btn-about-close');
const aboutVersion = document.getElementById('about-version');
const aboutBuildTime = document.getElementById('about-build-time');

function fmtBuildTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
async function openAbout() {
  const info = await api.about();
  aboutVersion.textContent = 'v' + (info.version || '?');
  aboutBuildTime.textContent = fmtBuildTime(info.buildTime);
  aboutMask.classList.remove('hidden');
}
btnAbout.addEventListener('click', openAbout);
btnAboutClose.addEventListener('click', () => aboutMask.classList.add('hidden'));
aboutMask.addEventListener('click', (e) => {
  if (e.target === aboutMask) aboutMask.classList.add('hidden');
});
window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') aboutMask.classList.add('hidden');
});

// ── 日志渲染 ──
function pad(n) { return String(n).padStart(2, '0'); }
function fmtTime(ts) {
  const d = new Date(ts || Date.now());
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
const LEVEL_LABEL = { info: 'INFO', ok: 'OK', warn: 'WARN', err: 'ERR', cmd: 'CMD', step: 'STEP' };

function appendLog(entry) {
  const data = entry && typeof entry === 'object' ? entry : {};
  const level = Object.prototype.hasOwnProperty.call(LEVEL_LABEL, data.level) ? data.level : 'info';
  const text = typeof data.text === 'string' ? data.text.slice(0, 8192) : String(data.text || '');
  const line = document.createElement('div');
  line.className = 'log-line';
  const time = document.createElement('span');
  time.className = 'log-time';
  time.textContent = fmtTime(data.ts);
  const lvl = document.createElement('span');
  lvl.className = `log-level ${level}`;
  lvl.textContent = LEVEL_LABEL[level];
  const txt = document.createElement('span');
  txt.className = 'log-text';
  txt.textContent = text;
  line.appendChild(time);
  line.appendChild(lvl);
  line.appendChild(txt);
  els.log.appendChild(line);
  els.log.scrollTop = els.log.scrollHeight;
}

// ── 步骤条 ──
function updateStep(id, status) {
  const safeStatuses = ['active', 'done', 'skipped', 'error'];
  const nodes = $$('.step');
  nodes.forEach(n => {
    if (n.dataset.step === id) {
      n.classList.remove('active', 'done', 'skipped', 'error');
      if (safeStatuses.includes(status)) n.classList.add(status);
    }
  });
}

// ── 进度 ──
function updateProgress({ step, percent, detail }) {
  const numericPercent = Number(percent);
  const safePercent = Number.isFinite(numericPercent)
    ? Math.max(0, Math.min(100, Math.round(numericPercent)))
    : 0;
  els.progressFill.style.width = safePercent + '%';
  els.progressPercent.textContent = safePercent + '%';
  const title = {
    detect: '① 探测环境',
    git: '② 安装 Git Bash',
    claude: '③ 安装 Claude CLI',
    config: '④ 写入配置',
    path: '⑤ 配置系统 PATH',
    done: '✓ 全部完成',
  }[step] || '进行中';
  els.progressTitle.textContent = title;
  if (detail) els.progressDetail.textContent = String(detail).slice(0, 1024);
}

// ── IPC 事件 ──
api.onLog(appendLog);
api.onProgress(updateProgress);
api.onStep(({ id, status, extra }) => {
  updateStep(id, status);
  if (status === 'error' && extra && extra.message) {
    els.progressDetail.textContent = '❌ ' + extra.message;
  }
});

// ── 环境探测 ──
async function detect() {
  appendLog({ level: 'info', text: '开始探测本地环境…', ts: Date.now() });
  const state = await api.detect();
  const parts = [];
  parts.push(`Git ${state.git.installed ? '✓ ' + (state.git.location || '') : '✗ 未安装'}`);
  parts.push(`Claude ${state.claude.installed ? '✓ ' + (state.claude.location || '') : '✗ 未安装'}`);
  parts.push(`系统 PATH 含 ${state.path.binDir}：${state.path.hasBin ? '是' : '否'}`);
  appendLog({ level: 'ok', text: '探测完成：' + parts.join(' | '), ts: Date.now() });

  els.optGit.checked = !state.git.installed;
  els.optGitHint.textContent = state.git.installed
    ? '本机已安装，勾选无效（自动跳过）'
    : '默认安装到 C:\\Program Files\\Git';
}
els.btnDetect.addEventListener('click', detect);
window.addEventListener('DOMContentLoaded', async () => {
  await detect();
});

// ── 日志工具 ──
els.btnCopyLog.addEventListener('click', () => {
  navigator.clipboard.writeText(els.log.innerText || '');
});
els.btnClearLog.addEventListener('click', () => clearElement(els.log));
els.btnOpenLog.addEventListener('click', () => api.openLogFile());
els.btnVerify.addEventListener('click', async () => {
  els.btnVerify.disabled = true;
  try {
    const result = await api.verifyClaude();
    appendLog({
      level: result && result.ok ? 'ok' : 'err',
      text: result && result.ok
        ? `Claude CLI 验证通过：${String(result.version || '').slice(0, 256)}`
        : 'Claude CLI 验证失败，请重新安装后再试。',
      ts: Date.now(),
    });
  } catch (error) {
    appendLog({ level: 'err', text: 'Claude CLI 验证失败，请重新安装后再试。', ts: Date.now() });
  } finally {
    els.btnVerify.disabled = false;
  }
});

// ── 开始/取消 ──
els.btnStart.addEventListener('click', async () => {
  if (mainInstallBusy || ccSwitchBusy) return;
  mainInstallBusy = true;
  syncOperationButtons();
  els.btnCancel.classList.remove('hidden');
  try {
    await api.startInstall({ installGit: els.optGit.checked });
    els.btnCancel.classList.add('hidden');
    els.btnVerify.classList.remove('hidden');
    els.btnStart.textContent = '重新安装';
    appendLog({ level: 'ok', text: '全部步骤完成。若在自己的 CMD/PowerShell 中提示 “claude 不是内部或外部命令”，请重新打开终端或注销后重登再试。', ts: Date.now() });
  } catch (e) {
    appendLog({ level: 'err', text: '安装失败：' + (e && e.message || e), ts: Date.now() });
    els.btnStart.textContent = '重试';
  } finally {
    mainInstallBusy = false;
    els.btnCancel.classList.add('hidden');
    els.btnCancel.disabled = false;
    els.btnCancel.textContent = '取消';
    syncOperationButtons();
  }
});
els.btnCancel.addEventListener('click', () => {
  if (!mainInstallBusy || els.btnCancel.disabled) return;
  api.cancel();
  els.btnCancel.disabled = true;
  els.btnCancel.textContent = '正在取消…';
  appendLog({ level: 'warn', text: '已发送取消请求，等待当前操作中止…', ts: Date.now() });
});

async function runCCSwitchInstall() {
  if (ccSwitchBusy || ccSwitchInstalled || mainInstallBusy) return;
  ccSwitchBusy = true;
  els.btnCCSwitch.textContent = '安装中…';
  syncOperationButtons();
  appendLog({ level: 'info', text: '开始安装 CC Switch…', ts: Date.now() });
  try {
    await api.installCCSwitch();
    ccSwitchInstalled = true;
    els.btnCCSwitch.textContent = '已安装 CC Switch ✓';
    appendLog({ level: 'ok', text: 'CC Switch 安装完成！从开始菜单启动。', ts: Date.now() });
  } catch (e) {
    appendLog({ level: 'err', text: 'CC Switch 安装失败：' + (e && e.message || e), ts: Date.now() });
    els.btnCCSwitch.textContent = ccSwitchLabel + '（重试）';
  } finally {
    ccSwitchBusy = false;
    syncOperationButtons();
  }
}

els.btnCCSwitch.addEventListener('click', runCCSwitchInstall);
