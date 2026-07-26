/** Fixed Windows system executables and a minimal child-process environment. */
const path = require('path');

const WINDOWS_ROOT = 'C:\\Windows';
const SYSTEM32 = `${WINDOWS_ROOT}\\System32`;
const EXECUTABLES = Object.freeze({
  msiexec: `${SYSTEM32}\\msiexec.exe`,
  reg: `${SYSTEM32}\\reg.exe`,
  taskkill: `${SYSTEM32}\\taskkill.exe`,
  whoami: `${SYSTEM32}\\whoami.exe`,
});

function addUserPath(result, key) {
  const value = process.env[key];
  if (typeof value === 'string' && value.length <= 32767
      && path.win32.isAbsolute(value) && !/[\u0000-\u001f\u007f]/.test(value)) {
    result[key] = value;
  }
}

function systemEnvironment() {
  const result = {
    SystemDrive: 'C:',
    SystemRoot: WINDOWS_ROOT,
    WINDIR: WINDOWS_ROOT,
    COMSPEC: `${SYSTEM32}\\cmd.exe`,
    PATH: `${SYSTEM32};${WINDOWS_ROOT}`,
    PATHEXT: '.COM;.EXE;.BAT;.CMD',
    PROGRAMDATA: 'C:\\ProgramData',
    TEMP: `${WINDOWS_ROOT}\\Temp`,
    TMP: `${WINDOWS_ROOT}\\Temp`,
    PROCESSOR_ARCHITECTURE: process.arch === 'arm64' ? 'ARM64' : 'AMD64',
  };
  ['USERPROFILE', 'APPDATA', 'LOCALAPPDATA'].forEach((key) => addUserPath(result, key));
  return result;
}

function systemOptions(extra) {
  return Object.assign({
    cwd: SYSTEM32,
    env: systemEnvironment(),
    shell: false,
    windowsHide: true,
  }, extra || {});
}

module.exports = { EXECUTABLES, SYSTEM32, WINDOWS_ROOT, systemEnvironment, systemOptions };
