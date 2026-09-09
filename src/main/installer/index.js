/**
 * 安装编排器：串起 detect → git → claude → config → path 各步骤，
 * 每步向 renderer 推送 step 状态与进度。
 */
const detect = require('./detect');
const git = require('./gitInstaller');
const claude = require('./claudeRunner');
const config = require('./configWriter');
const pathMgr = require('./pathManager');
const logger = require('../logger');
const env = require('../env');
const path = require('path');
const { execFile } = require('child_process');
const { createAbortController } = require('./downloader');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

const STEPS = {
  DETECT: 'detect',
  GIT: 'git',
  CLAUDE: 'claude',
  CONFIG: 'config',
  PATH: 'path',
  DONE: 'done',
};

class Installer {
  constructor(win, opts) {
    this.win = win;
    this.opts = opts || {};
    this.cancelled = false;
    this.abortController = createAbortController();
    this.activeChild = null; // 当前正在跑的子进程（Git 静默安装 / PowerShell / msiexec 等）
  }
  cancel() {
    if (this.cancelled) return;
    this.cancelled = true;
    logger.warn('收到取消请求，正在中止当前操作…');
    try { this.abortController.abort(); } catch {}
    try {
      if (this.activeChild && !this.activeChild.killed) {
        // Windows 上纯 SIGTERM 对 GUI 子进程不总管用，用 taskkill /T /F 递归杀
        const pid = this.activeChild.pid;
        try {
          execFile(EXECUTABLES.taskkill, ['/pid', String(pid), '/T', '/F'],
            systemOptions({ timeout: 10000, maxBuffer: 64 * 1024 }), () => {});
        } catch {}
        try { this.activeChild.kill('SIGTERM'); } catch {}
      }
    } catch {}
  }
  registerChild(child) { this.activeChild = child; }
  clearChild() { this.activeChild = null; }

  checkCancel() {
    if (this.cancelled) throw new Error('用户已取消安装');
  }

  async run() {
    try {
      // ── ① 环境探测 ──
      logger.setStep(STEPS.DETECT, 'active');
      logger.progress(STEPS.DETECT, 0, '探测环境…');
      const state = await detect.run();
      logger.info(`Git: ${state.git.installed ? '已装 ' + state.git.location : '未装'}`);
      logger.info(`Claude: ${state.claude.installed ? '已装 ' + state.claude.location : '未装'}`);
      logger.info(`系统 PATH 含 ${state.path.binDir}: ${state.path.hasBin ? '是' : '否'}`);
      logger.progress(STEPS.DETECT, 100);
      logger.setStep(STEPS.DETECT, 'done');

      // ── ② Git Bash 安装 ──
      this.checkCancel();
      if (this.opts.installGit && !state.git.installed) {
        logger.setStep(STEPS.GIT, 'active');
        await git.install((p) => {
          logger.progress(STEPS.GIT, p.percent, `${(p.loaded / 1048576).toFixed(1)} / ${(p.total / 1048576).toFixed(1)} MB`);
        }, this);
        logger.progress(STEPS.GIT, 100);
        logger.setStep(STEPS.GIT, 'done');
      } else {
        logger.setStep(STEPS.GIT, 'skipped');
        logger.info(this.opts.installGit ? 'Git 已安装，跳过' : '用户选择跳过 Git 安装');
      }

      // 本次实际要校验的 claude 可执行文件：新装用安装目录，已装则用探测到的现有路径。
      const claudeExecutable = state.claude.installed && state.claude.location
        ? state.claude.location
        : path.join(env.INSTALL_BIN_DIR, 'claude.exe');

      // ── ③ Claude CLI 安装（已安装则跳过，便于只补装 Git）──
      this.checkCancel();
      if (state.claude.installed) {
        logger.info(`Claude CLI 已安装（${state.claude.location}），跳过`);
        logger.setStep(STEPS.CLAUDE, 'skipped');
        // 本次未改动 Claude，配置与 PATH 由其原有安装方式负责，无需重复校验。
        logger.setStep(STEPS.CONFIG, 'skipped');
        logger.setStep(STEPS.PATH, 'skipped');
        logger.progress(STEPS.CLAUDE, 100);
      } else {
        logger.setStep(STEPS.CLAUDE, 'active');
        logger.info(`安装方式：${env.INSTALL_SCRIPT.name}`);
        logger.progress(STEPS.CLAUDE, 0, '开始执行内置 Claude 安装脚本…');
        await claude.install(env.INSTALL_SCRIPT, this);
        logger.progress(STEPS.CLAUDE, 100);
        logger.setStep(STEPS.CLAUDE, 'done');

        // ── ④ 验证 .claude.json ──
        this.checkCancel();
        logger.setStep(STEPS.CONFIG, 'active');
        config.verify();
        logger.progress(STEPS.CONFIG, 100);
        logger.setStep(STEPS.CONFIG, 'done');

        // ── ⑤ 验证系统 PATH ──
        this.checkCancel();
        logger.setStep(STEPS.PATH, 'active');
        await pathMgr.verifyBinInPath();
        logger.progress(STEPS.PATH, 100);
        logger.setStep(STEPS.PATH, 'done');
      }

      // ── ⑥ 完成 ──
      await this.finalCheck(claudeExecutable);
      logger.setStep(STEPS.DONE, 'done');
      logger.ok('✅ 安装完成');
    } catch (e) {
      const msg = e.message || String(e);
      if (this.cancelled) {
        logger.warn('安装已取消');
        logger.setStep('error', 'error', { message: '已取消' });
      } else {
        logger.err(msg);
        logger.setStep('error', 'error', { message: msg });
      }
      throw e;
    }
  }

  async finalCheck(executable) {
    return new Promise((resolve, reject) => {
      execFile(executable || path.join(env.INSTALL_BIN_DIR, 'claude.exe'), ['--version'],
        systemOptions({ timeout: 10000, maxBuffer: 4096 }), (err, stdout) => {
          const version = String(stdout || '').split(/\r?\n/, 1)[0]
            .replace(/[^\x20-\x7e]/g, '').trim().slice(0, 256);
          if (err || !version) {
            reject(new Error('Claude CLI 安装后验证失败'));
            return;
          }
          logger.ok(`claude --version → ${version}`);
          resolve();
        });
    });
  }
}

module.exports = Installer;
