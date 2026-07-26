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
const { execFile } = require('child_process');
const { cleanRootEnvironment, findTrustedExecutable } = require('./privilege');

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
    this.activeChild = null;
  }

  cancel() {
    if (this.cancelled) return;
    this.cancelled = true;
    logger.warn('收到取消请求，正在中止当前操作…');
    try {
      if (this.activeChild && !this.activeChild.killed) {
        const pid = this.activeChild.pid;
        const kill = findTrustedExecutable(['/bin/kill', '/usr/bin/kill']);
        if (kill && Number.isSafeInteger(pid) && pid > 0) {
          try {
            execFile(kill, ['-TERM', '--', `-${pid}`],
              { env: cleanRootEnvironment() }, () => {});
          } catch (_) {}
        }
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
      logger.info(`全局命令入口 ${state.path.linkPath}: ${state.path.hasBin ? '已就绪' : '未就绪'}`);
      logger.progress(STEPS.DETECT, 100);
      logger.setStep(STEPS.DETECT, 'done');

      // ── ② Git 安装 ──
      this.checkCancel();
      if (this.opts.installGit && !state.git.installed) {
        logger.setStep(STEPS.GIT, 'active');
        await git.install((p) => {
          logger.progress(STEPS.GIT, p.percent, p.detail || '安装 Git…');
        }, this);
        logger.progress(STEPS.GIT, 100);
        logger.setStep(STEPS.GIT, 'done');
      } else {
        logger.setStep(STEPS.GIT, 'skipped');
        logger.info(this.opts.installGit ? 'Git 已安装，跳过' : '用户选择跳过 Git 安装');
      }

      // ── ③ Claude CLI 安装 ──
      this.checkCancel();
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

      // ── ⑤ 验证全局命令入口 ──
      this.checkCancel();
      logger.setStep(STEPS.PATH, 'active');
      pathMgr.verifyGlobalCommand();
      logger.progress(STEPS.PATH, 100);
      logger.setStep(STEPS.PATH, 'done');

      // ── ⑥ 完成 ──
      await this.finalCheck();
      logger.setStep(STEPS.DONE, 'done');
      logger.ok('安装完成');
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

  async finalCheck() {
    return new Promise((resolve, reject) => {
      execFile(env.GLOBAL_CLAUDE_LINK, ['--version'],
        {
          env: cleanRootEnvironment(),
          timeout: 10000,
          maxBuffer: 4096,
        }, (err, stdout) => {
          const version = String(stdout || '').split(/\r?\n/, 1)[0]
            .replace(/[^\x20-\x7e]/g, '').trim().slice(0, 256);
          if (err) {
            reject(new Error('Claude CLI 安装后验证失败'));
            return;
          }
          if (!version) {
            reject(new Error('Claude CLI 安装后未返回有效版本'));
            return;
          }
          logger.ok(`claude --version → ${version}`);
          resolve();
        });
    });
  }
}

module.exports = Installer;
