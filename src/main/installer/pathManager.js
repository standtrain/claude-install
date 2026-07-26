/** Verify the machine PATH entry written by the bundled PowerShell script. */
const { execFile } = require('child_process');
const env = require('../env');
const logger = require('../logger');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

const MACHINE_ENVIRONMENT_KEY = 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment';

function readMachinePath() {
  return new Promise((resolve, reject) => {
    execFile(EXECUTABLES.reg, ['query', MACHINE_ENVIRONMENT_KEY, '/v', 'Path'],
      systemOptions({ timeout: 5000, maxBuffer: 64 * 1024 }), (error, stdout) => {
        if (error) {
          reject(new Error('无法读取系统 PATH'));
          return;
        }
        const match = String(stdout).match(/Path\s+REG_[A-Z_]+\s+([^\r\n]+)/i);
        const value = match ? match[1].trim() : '';
        if (value.length > 32767 || /[\u0000-\u001f\u007f]/.test(value)) {
          reject(new Error('系统 PATH 内容无效'));
          return;
        }
        resolve(value);
      });
  });
}

async function verifyBinInPath() {
  const current = await readMachinePath();
  const target = env.INSTALL_BIN_DIR.toLowerCase();
  const present = current.split(';').map((entry) => entry.trim().toLowerCase())
    .filter(Boolean).some((entry) => entry === target);
  if (!present) throw new Error(`系统 PATH 未包含 ${env.INSTALL_BIN_DIR}`);
  logger.ok(`系统 PATH 验证通过：${env.INSTALL_BIN_DIR}`);
  return { changed: false };
}

module.exports = { readMachinePath, verifyBinInPath };
