/**
 * Verify the global command created by the bundled root installer. The GUI
 * process remains unprivileged and never mutates /usr/local/bin directly.
 */
const fs = require('fs');
const path = require('path');
const env = require('../env');
const logger = require('../logger');

function resolvedLinkTarget(linkPath, target) {
  return path.posix.resolve(path.posix.dirname(linkPath), target);
}

function verifyGlobalCommand() {
  const globalLink = env.GLOBAL_CLAUDE_LINK;
  const managedLink = path.posix.join(env.INSTALL_BIN_DIR, 'claude');
  const versionsRoot = path.posix.join(env.INSTALL_ROOT, 'versions');

  let globalStat;
  let managedStat;
  try {
    globalStat = fs.lstatSync(globalLink);
    managedStat = fs.lstatSync(managedLink);
  } catch (error) {
    throw new Error(`Claude 全局命令不存在：${error.message}`);
  }
  if (!globalStat.isSymbolicLink() || globalStat.uid !== 0) {
    throw new Error(`${globalLink} 必须是 root 创建的符号链接`);
  }
  if (!managedStat.isSymbolicLink() || managedStat.uid !== 0) {
    throw new Error(`${managedLink} 必须是 root 创建的符号链接`);
  }

  const globalTarget = resolvedLinkTarget(globalLink, fs.readlinkSync(globalLink));
  if (globalTarget !== path.posix.resolve(managedLink)) {
    throw new Error(`${globalLink} 指向了非托管目标`);
  }
  const binaryTarget = resolvedLinkTarget(managedLink, fs.readlinkSync(managedLink));
  const versionPrefix = `${path.posix.resolve(versionsRoot)}/`;
  if (binaryTarget.indexOf(versionPrefix) !== 0) {
    throw new Error(`${managedLink} 指向了版本目录之外`);
  }

  const binaryStat = fs.lstatSync(binaryTarget);
  if (!binaryStat.isFile() || binaryStat.isSymbolicLink() || binaryStat.uid !== 0
      || (binaryStat.mode & 0o022) !== 0 || (binaryStat.mode & 0o111) === 0) {
    throw new Error('Claude 安装目标的类型、所有者或权限无效');
  }

  logger.ok(`全局命令入口验证通过：${globalLink} -> ${managedLink}`);
  return { changed: false, linkPath: globalLink, target: managedLink, binaryTarget };
}

module.exports = { resolvedLinkTarget, verifyGlobalCommand };
