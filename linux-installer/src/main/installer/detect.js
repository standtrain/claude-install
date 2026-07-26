/**
 * 环境探测：git、claude，以及 /usr/local/bin/claude 全局命令入口。
 */
const fs = require('fs');
const path = require('path');
const env = require('../env');

function fileExists(p) {
  try { return fs.statSync(p).isFile(); } catch (_) { return false; }
}

function commandPath(command, searchPath) {
  if (!/^[a-z0-9._-]{1,64}$/i.test(command)) return null;
  const directories = String(searchPath || '').split(':').slice(0, 128);
  for (const directory of directories) {
    if (!directory || directory.length > 4096 || directory.indexOf('\0') !== -1
        || !path.posix.isAbsolute(directory) || path.posix.normalize(directory) !== directory) continue;
    const candidate = path.posix.join(directory, command);
    try {
      const stat = fs.statSync(candidate);
      if (stat.isFile()) {
        fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      }
    } catch (_) {}
  }
  return null;
}

function which(command) {
  return Promise.resolve(commandPath(command, process.env.PATH));
}

function globalLinkReady() {
  try {
    const linkPath = env.GLOBAL_CLAUDE_LINK;
    const target = path.posix.join(env.INSTALL_BIN_DIR, 'claude');
    const stat = fs.lstatSync(linkPath);
    if (!stat.isSymbolicLink()) return false;
    const currentTarget = path.posix.resolve(path.posix.dirname(linkPath), fs.readlinkSync(linkPath));
    return currentTarget === path.posix.resolve(target) && fileExists(linkPath);
  } catch (_) { return false; }
}

async function run() {
  const gitPath = await which('git');
  const claudePath = await which('claude');

  const claudeCandidates = [
    env.GLOBAL_CLAUDE_LINK,
    path.posix.join(env.INSTALL_BIN_DIR, 'claude'),
  ];
  if (typeof process.env.HOME === 'string' && path.posix.isAbsolute(process.env.HOME)) {
    claudeCandidates.push(path.posix.join(process.env.HOME, '.local', 'bin', 'claude'));
  }
  const claudeLocations = claudeCandidates.filter(fileExists);
  const claudeInstalled = Boolean(claudePath) || claudeLocations.length > 0;

  return {
    git: {
      installed: Boolean(gitPath),
      location: gitPath || null,
    },
    claude: {
      installed: claudeInstalled,
      location: claudePath || claudeLocations[0] || null,
    },
    path: {
      hasBin: globalLinkReady(),
      binDir: env.GLOBAL_BIN_DIR,
      linkPath: env.GLOBAL_CLAUDE_LINK,
    },
  };
}

module.exports = { commandPath, fileExists, globalLinkReady, run, which };
