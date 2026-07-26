/**
 * 管理员权限检测。全应用打包时 requireAdministrator，此模块提供开发态兜底提示。
 */
const { execFile } = require('child_process');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

function isAdmin() {
  return new Promise((resolve) => {
    // whoami /groups 输出含 S-1-16-12288 表示高完整性级别（管理员令牌）
    execFile(EXECUTABLES.whoami, ['/groups'], systemOptions({
      timeout: 5000,
      maxBuffer: 64 * 1024,
    }), (err, stdout) => {
      if (err) return resolve(false);
      resolve(/S-1-16-12288/.test(stdout));
    });
  });
}

module.exports = { isAdmin };
