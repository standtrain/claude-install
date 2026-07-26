/** Verify the user config written by the bundled PowerShell installer. */
const fs = require('fs');
const path = require('path');
const os = require('os');
const logger = require('../logger');

const MAX_CONFIG_BYTES = 1024 * 1024;

function readConfig(target) {
  if (!fs.existsSync(target)) throw new Error('.claude.json 不存在');
  const linkStat = fs.lstatSync(target);
  if (linkStat.isSymbolicLink() || !linkStat.isFile()) {
    throw new Error('.claude.json 必须是普通文件');
  }

  const descriptor = fs.openSync(target, fs.constants.O_RDONLY);
  let content;
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) throw new Error('.claude.json 必须是普通文件');
    if (stat.size > MAX_CONFIG_BYTES) {
      throw new Error('.claude.json 超过 1 MB');
    }
    const chunks = [];
    let total = 0;
    while (total <= MAX_CONFIG_BYTES) {
      const buffer = Buffer.alloc(Math.min(64 * 1024, MAX_CONFIG_BYTES + 1 - total));
      const bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      chunks.push(bytesRead === buffer.length ? buffer : buffer.slice(0, bytesRead));
      total += bytesRead;
    }
    if (total > MAX_CONFIG_BYTES) throw new Error('.claude.json 超过 1 MB');
    content = Buffer.concat(chunks, total);
  } finally {
    fs.closeSync(descriptor);
  }

  let raw = content.toString('utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    throw new Error('.claude.json 不是有效 JSON');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('.claude.json 顶层必须是对象');
  }
  return parsed;
}

function verify() {
  const target = path.join(os.homedir(), '.claude.json');
  const data = readConfig(target);
  if (data.hasCompletedOnboarding !== true) {
    throw new Error('.claude.json 缺少 hasCompletedOnboarding=true');
  }
  logger.ok(`配置文件验证通过：${target}`);
  return { path: target };
}

module.exports = { readConfig, verify };
