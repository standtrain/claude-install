/**
 * Linux privilege boundary: resolve trusted system executables and build a
 * minimal, non-interactive root command for direct-root or pkexec execution.
 */
const fs = require('fs');

const SAFE_EXEC_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
const BASE_ENVIRONMENT = {
  PATH: SAFE_EXEC_PATH,
  HOME: '/root',
  USER: 'root',
  LOGNAME: 'root',
  LANG: 'C.UTF-8',
};

function findTrustedExecutable(candidates) {
  const list = Array.isArray(candidates) ? candidates : [candidates];
  for (const candidate of list) {
    if (typeof candidate !== 'string' || candidate.length === 0) continue;
    try {
      const real = fs.realpathSync(candidate);
      const stat = fs.statSync(real);
      if (stat.isFile() && stat.uid === 0 && (stat.mode & 0o022) === 0) return real;
    } catch (_) {}
  }
  return null;
}

function trustedExecutable(candidates, label) {
  const executable = findTrustedExecutable(candidates);
  if (!executable) throw new Error(`未找到可信的 ${label}`);
  return executable;
}

function validateAssignments(extra) {
  const result = {};
  Object.keys(extra || {}).forEach((key) => {
    const value = extra[key];
    if (!/^[A-Z_][A-Z0-9_]{0,63}$/.test(key)
        || typeof value !== 'string' || value.length > 1024
        || /[\u0000-\u001f\u007f]/.test(value)) {
      throw new Error('提权进程环境变量无效');
    }
    result[key] = value;
  });
  return result;
}

function cleanRootEnvironment(extra) {
  return Object.assign({}, BASE_ENVIRONMENT, validateAssignments(extra));
}

function createRootCommand(executable, args, extraEnvironment) {
  const uid = typeof process.getuid === 'function' ? process.getuid() : -1;
  if (!Number.isSafeInteger(uid) || uid < 0) throw new Error('无法确认当前用户身份');
  const targetArgs = Array.isArray(args) ? args.slice() : [];
  const extra = validateAssignments(extraEnvironment);

  if (uid === 0) {
    return {
      executable,
      args: targetArgs,
      env: cleanRootEnvironment(extra),
      elevated: false,
    };
  }

  const pkexec = trustedExecutable(['/usr/bin/pkexec', '/bin/pkexec'], 'pkexec');
  const envProgram = trustedExecutable(['/usr/bin/env', '/bin/env'], 'env');
  const rootEnvironment = cleanRootEnvironment(Object.assign({}, extra, {
    PKEXEC_UID: String(uid),
  }));
  const assignments = Object.keys(rootEnvironment)
    .sort()
    .map((key) => `${key}=${rootEnvironment[key]}`);

  return {
    executable: pkexec,
    args: [envProgram, '-i'].concat(assignments, [executable], targetArgs),
    // pkexec resolves the active PolicyKit session from the caller PID. Its
    // target receives only the explicit env -i assignments above.
    env: { PATH: SAFE_EXEC_PATH, LANG: 'C.UTF-8' },
    elevated: true,
  };
}

module.exports = {
  SAFE_EXEC_PATH,
  cleanRootEnvironment,
  createRootCommand,
  findTrustedExecutable,
  trustedExecutable,
};
