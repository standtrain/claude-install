/**
 * 将配置写入提权前的真实用户目录，文件和备份权限固定为 600。
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const logger = require('../logger');

const MAX_CONFIG_BYTES = 1024 * 1024;
const USERNAME_PATTERN = /^[a-z_][a-z0-9_-]{0,31}\$?$/i;

function passwdEntries() {
  const raw = fs.readFileSync('/etc/passwd', 'utf8');
  if (Buffer.byteLength(raw, 'utf8') > MAX_CONFIG_BYTES) throw new Error('/etc/passwd 大小异常');
  return raw.split(/\r?\n/).map((line) => line.split(':')).filter((parts) => parts.length >= 7);
}

function resolveTargetUserFromEntries(entries, runtimeEnv, currentUid) {
  const sudoUser = runtimeEnv.SUDO_USER;
  const pkexecUid = runtimeEnv.PKEXEC_UID;
  let entry = null;

  if (sudoUser && sudoUser !== 'root') {
    if (!USERNAME_PATTERN.test(sudoUser)) throw new Error('SUDO_USER 格式无效');
    entry = entries.find((parts) => parts[0] === sudoUser) || null;
    if (!entry) throw new Error('SUDO_USER 指定的用户不存在，已拒绝回退到 root');
  } else if (pkexecUid) {
    if (!/^\d{1,10}$/.test(pkexecUid)) throw new Error('PKEXEC_UID 格式无效');
    entry = entries.find((parts) => parts[2] === pkexecUid) || null;
    if (!entry) throw new Error('PKEXEC_UID 指定的用户不存在，已拒绝回退到 root');
  } else {
    entry = entries.find((parts) => Number(parts[2]) === currentUid) || null;
  }
  if (!entry) throw new Error('无法定位配置文件所属用户');

  const uid = Number(entry[2]);
  const gid = Number(entry[3]);
  const home = entry[5];
  if (!Number.isSafeInteger(uid) || !Number.isSafeInteger(gid)
      || typeof home !== 'string' || home.length === 0 || home.length > 4096
      || !path.posix.isAbsolute(home) || home.indexOf('\0') !== -1 || path.posix.normalize(home) !== home
      || !USERNAME_PATTERN.test(entry[0]) || uid < 0 || gid < 0) {
    throw new Error('用户目录信息无效');
  }
  return { name: entry[0], uid, gid, home };
}

function resolveTargetUser() {
  const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
  return resolveTargetUserFromEntries(passwdEntries(), process.env, uid);
}

function noFollowFlag() {
  if (typeof fs.constants.O_NOFOLLOW !== 'number') {
    throw new Error('当前平台不支持 O_NOFOLLOW，已拒绝以高权限读写用户配置');
  }
  return fs.constants.O_NOFOLLOW;
}

function writeBuffer(fd, content) {
  let offset = 0;
  while (offset < content.length) {
    const written = fs.writeSync(fd, content, offset, content.length - offset, null);
    if (written <= 0) throw new Error('配置文件写入未完成');
    offset += written;
  }
}

function createPrivateFile(filePath, content, owner) {
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT
    | fs.constants.O_EXCL | noFollowFlag();
  const fd = fs.openSync(filePath, flags, 0o600);
  try {
    writeBuffer(fd, content);
    fs.fchmodSync(fd, 0o600);
    fs.fchownSync(fd, owner.uid, owner.gid);
  } finally {
    fs.closeSync(fd);
  }
}

function backupConfig(target, content, owner) {
  const suffix = crypto.randomBytes(8).toString('hex');
  const backup = `${target}.bak.${Date.now()}-${suffix}`;
  createPrivateFile(backup, content, owner);
  logger.info(`已备份原配置到 ${backup}`);
  return backup;
}

function readLimitedBuffer(fd) {
  const chunks = [];
  let total = 0;
  while (total <= MAX_CONFIG_BYTES) {
    const remaining = MAX_CONFIG_BYTES + 1 - total;
    const chunk = Buffer.alloc(Math.min(64 * 1024, remaining));
    const bytesRead = fs.readSync(fd, chunk, 0, chunk.length, null);
    if (bytesRead === 0) break;
    chunks.push(bytesRead === chunk.length ? chunk : chunk.slice(0, bytesRead));
    total += bytesRead;
  }
  return Buffer.concat(chunks, total);
}

function readConfig(target, owner) {
  let fd;
  try {
    fd = fs.openSync(target, fs.constants.O_RDONLY | noFollowFlag());
  } catch (error) {
    if (error && error.code === 'ENOENT') return {};
    if (error && error.code === 'ELOOP') {
      throw new Error('原 .claude.json 不能是符号链接，已停止写入');
    }
    throw error;
  }

  let content;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new Error('原 .claude.json 必须是普通文件，已停止写入');
    if (stat.size > MAX_CONFIG_BYTES) {
      throw new Error('原 .claude.json 超过 1 MB，已保留原文件并停止覆盖');
    }
    content = readLimitedBuffer(fd);
    if (content.length > MAX_CONFIG_BYTES) {
      throw new Error('原 .claude.json 超过 1 MB，已保留原文件并停止覆盖');
    }
  } finally {
    fs.closeSync(fd);
  }

  backupConfig(target, content, owner);
  let raw = content.toString('utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  let parsed;
  try { parsed = JSON.parse(raw); }
  catch (_) { throw new Error('原 .claude.json 不是有效 JSON，已备份并保留原文件'); }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('原 .claude.json 顶层必须是对象，已备份并保留原文件');
  }
  return parsed;
}

function writeConfigAtomic(target, data, owner) {
  const suffix = crypto.randomBytes(8).toString('hex');
  const temp = `${target}.tmp-${process.pid}-${suffix}`;
  const content = Buffer.from(`${JSON.stringify(data, null, 2)}\n`, 'utf8');
  try {
    createPrivateFile(temp, content, owner);
    // 同目录 rename 在 Linux 上原子替换目标，且不会跟随目标符号链接。
    fs.renameSync(temp, target);
  } finally {
    try { fs.unlinkSync(temp); } catch (_) {}
  }
}

function verify() {
  const owner = resolveTargetUser();
  const target = path.posix.join(owner.home, '.claude.json');
  let fd;
  try {
    fd = fs.openSync(target, fs.constants.O_RDONLY | noFollowFlag());
  } catch (error) {
    if (error && error.code === 'ELOOP') {
      throw new Error('.claude.json 不能是符号链接');
    }
    throw new Error(`无法读取 .claude.json：${error.message}`);
  }

  let content;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== owner.uid || stat.gid !== owner.gid
        || (stat.mode & 0o777) !== 0o600 || stat.size > MAX_CONFIG_BYTES) {
      throw new Error('.claude.json 的类型、所有者、权限或大小无效');
    }
    content = readLimitedBuffer(fd);
    if (content.length > MAX_CONFIG_BYTES) throw new Error('.claude.json 超过 1 MB');
  } finally {
    fs.closeSync(fd);
  }

  let raw = content.toString('utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  let parsed;
  try { parsed = JSON.parse(raw); } catch (_) { throw new Error('.claude.json 不是有效 JSON'); }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)
      || parsed.hasCompletedOnboarding !== true) {
    throw new Error('.claude.json 缺少 hasCompletedOnboarding=true');
  }
  logger.ok(`配置文件验证通过：${target}（权限 600）`);
  return { path: target };
}

function apply() {
  const owner = resolveTargetUser();
  const target = path.posix.join(owner.home, '.claude.json');
  const data = readConfig(target, owner);
  writeConfigAtomic(target, Object.assign({}, data, { hasCompletedOnboarding: true }), owner);
  logger.ok(`已安全写入 hasCompletedOnboarding=true 到 ${target}`);
  return { path: target };
}

module.exports = {
  apply,
  readConfig,
  resolveTargetUser,
  resolveTargetUserFromEntries,
  verify,
  writeConfigAtomic,
};
