/**
 * 环境探测：git、claude、系统 PATH 是否已含 ProgramData\claude\bin。
 */
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const env = require('../env');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

function fileExists(p) {
  try { return fs.statSync(p).isFile(); } catch (_) { return false; }
}

function commandPath(command, searchPath) {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(command)) return null;
  const executable = /\.exe$/i.test(command) ? command : `${command}.exe`;
  const directories = String(searchPath || '').split(';').slice(0, 128);
  for (const directory of directories) {
    const trimmed = directory.trim();
    if (!trimmed || trimmed.length > 32767 || !path.win32.isAbsolute(trimmed)
        || /[\u0000-\u001f\u007f]/.test(trimmed)) continue;
    const candidate = path.win32.join(path.win32.normalize(trimmed), executable);
    if (fileExists(candidate)) return candidate;
  }
  return null;
}

function which(command) {
  return Promise.resolve(commandPath(command, process.env.PATH));
}

function readSystemPath() {
  return new Promise((resolve) => {
    execFile(EXECUTABLES.reg, [
      'query',
      'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment',
      '/v', 'Path',
    ], systemOptions({ timeout: 5000, maxBuffer: 64 * 1024 }), (err, stdout) => {
      if (err) return resolve('');
      const m = String(stdout).match(/Path\s+REG_[A-Z_]+\s+([^\r\n]+)/i);
      resolve(m ? m[1].trim() : '');
    });
  });
}

async function run() {
  const gitPath = await which('git');
  const claudePath = await which('claude');
  const gitDefault = 'C:\\Program Files\\Git\\cmd\\git.exe';
  const gitInstalled = Boolean(gitPath) || fileExists(gitDefault);

  const claudeCandidates = [
    path.join(env.INSTALL_BIN_DIR, 'claude.exe'),
    path.join(process.env.USERPROFILE || '', '.local', 'bin', 'claude.exe'),
  ];
  const claudeLocations = claudeCandidates.filter(fileExists);
  const claudeInstalled = Boolean(claudePath) || claudeLocations.length > 0;

  const systemPath = await readSystemPath();
  const pathHasBin = systemPath.split(';').map(s => s.trim().toLowerCase())
    .includes(env.INSTALL_BIN_DIR.toLowerCase());

  return {
    git: {
      installed: gitInstalled,
      location: gitPath || (fileExists(gitDefault) ? gitDefault : null),
    },
    claude: {
      installed: claudeInstalled,
      location: claudePath || claudeLocations[0] || null,
    },
    path: {
      hasBin: pathHasBin,
      binDir: env.INSTALL_BIN_DIR,
    },
  };
}

module.exports = { commandPath, fileExists, readSystemPath, run, which };
