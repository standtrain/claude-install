const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const WINDOWS_TEMP_PARENT = 'C:\\ProgramData\\ClaudeInstallerTemp';
const WINDOWS_POWERSHELL = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const WINDOWS_POWERSHELL_TIMEOUT_MS = 10000;
const WINDOWS_POWERSHELL_ENV = {
  SystemDrive: 'C:',
  SystemRoot: 'C:\\Windows',
  TEMP: 'C:\\Windows\\Temp',
  TMP: 'C:\\Windows\\Temp',
};
const WINDOWS_TEMP_NAME_RE = /^claude-installer-[A-Za-z0-9._-]{1,64}-[a-f0-9]{32}$/;
// Security boundary: only directories created and verified in this process are usable.
const windowsDirectories = new Map();

function isLinux() {
  return process.platform === 'linux';
}

function isWindows() {
  return process.platform === 'win32';
}

function assertSafeName(name) {
  if (typeof name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) {
    throw new Error('Temporary file name is invalid');
  }
}

function createDirectorySecurityScript() {
  return [
    "$ErrorActionPreference = 'Stop'",
    "$parent = 'C:\\ProgramData\\ClaudeInstallerTemp'",
    '$name = $env:CLAUDE_INSTALLER_TEMP_NAME',
    "if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^claude-installer-[A-Za-z0-9._-]{1,64}-[a-f0-9]{32}$') { throw 'Invalid private temporary directory name' }",
    '$systemSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-18\')',
    '$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-32-544\')',
    '$rights = [System.Security.AccessControl.FileSystemRights]::FullControl',
    '$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit',
    '$propagation = [System.Security.AccessControl.PropagationFlags]::None',
    '$allow = [System.Security.AccessControl.AccessControlType]::Allow',
    'function New-PrivateDirectorySecurity {',
    '  $security = New-Object System.Security.AccessControl.DirectorySecurity',
    '  $security.SetOwner($administratorsSid)',
    '  $security.SetAccessRuleProtection($true, $false)',
    '  foreach ($sid in @($systemSid, $administratorsSid)) {',
    '    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rights, $inheritance, $propagation, $allow)',
    '    $security.AddAccessRule($rule)',
    '  }',
    '  return $security',
    '}',
    'function Assert-PrivateDirectory {',
    '  param([string] $directory)',
    "  if (-not [System.IO.Directory]::Exists($directory)) { throw 'Private temporary directory is missing' }",
    '  if (([System.IO.File]::GetAttributes($directory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw \'Private temporary directory is a reparse point\' }',
    '  $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner',
    '  $security = [System.IO.Directory]::GetAccessControl($directory, $sections)',
    "  if (-not $security.AreAccessRulesProtected) { throw 'Private temporary directory ACL is inherited' }",
    "  if ($security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'Private temporary directory owner is invalid' }",
    '  $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))',
    "  if ($rules.Count -ne 2) { throw 'Private temporary directory ACL has unexpected entries' }",
    "  foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {",
    '    $matches = @($rules | Where-Object { $_.IdentityReference.Value -eq $sidValue })',
    "    if ($matches.Count -ne 1) { throw 'Private temporary directory ACL identity is invalid' }",
    '    $rule = $matches[0]',
    "    if ($rule.IsInherited -or $rule.AccessControlType -ne $allow -or [int]$rule.FileSystemRights -ne [int]$rights -or $rule.InheritanceFlags -ne $inheritance -or $rule.PropagationFlags -ne $propagation) { throw 'Private temporary directory ACL rule is invalid' }",
    '  }',
    '}',
    'if ([System.IO.Directory]::Exists($parent)) {',
    '  Assert-PrivateDirectory $parent',
    '} else {',
    '  [System.IO.Directory]::CreateDirectory($parent, (New-PrivateDirectorySecurity)) | Out-Null',
    '  Assert-PrivateDirectory $parent',
    '}',
    '$directory = [System.IO.Path]::Combine($parent, $name)',
    "if ([System.IO.Directory]::Exists($directory) -or [System.IO.File]::Exists($directory)) { throw 'Private temporary directory already exists' }",
    '[System.IO.Directory]::CreateDirectory($directory, (New-PrivateDirectorySecurity)) | Out-Null',
    'Assert-PrivateDirectory $directory',
  ].join('\n');
}

function createVerifyDirectoryScript() {
  return [
    "$ErrorActionPreference = 'Stop'",
    '$directory = $env:CLAUDE_INSTALLER_TEMP_TARGET',
    "if ([string]::IsNullOrWhiteSpace($directory)) { throw 'Private temporary directory target is missing' }",
    '$systemSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-18\')',
    '$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-32-544\')',
    '$rights = [System.Security.AccessControl.FileSystemRights]::FullControl',
    '$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit',
    '$propagation = [System.Security.AccessControl.PropagationFlags]::None',
    '$allow = [System.Security.AccessControl.AccessControlType]::Allow',
    "if (-not [System.IO.Directory]::Exists($directory)) { throw 'Private temporary directory is missing' }",
    "if (([System.IO.File]::GetAttributes($directory) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Private temporary directory is a reparse point' }",
    '$sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner',
    '$security = [System.IO.Directory]::GetAccessControl($directory, $sections)',
    "if (-not $security.AreAccessRulesProtected) { throw 'Private temporary directory ACL is inherited' }",
    "if ($security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw 'Private temporary directory owner is invalid' }",
    '$rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))',
    "if ($rules.Count -ne 2) { throw 'Private temporary directory ACL has unexpected entries' }",
    "foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {",
    '  $matches = @($rules | Where-Object { $_.IdentityReference.Value -eq $sidValue })',
    "  if ($matches.Count -ne 1) { throw 'Private temporary directory ACL identity is invalid' }",
    '  $rule = $matches[0]',
    "  if ($rule.IsInherited -or $rule.AccessControlType -ne $allow -or [int]$rule.FileSystemRights -ne [int]$rights -or $rule.InheritanceFlags -ne $inheritance -or $rule.PropagationFlags -ne $propagation) { throw 'Private temporary directory ACL rule is invalid' }",
    '}',
  ].join('\n');
}

function createVerifyFileScript() {
  return [
    "$ErrorActionPreference = 'Stop'",
    '$filePath = $env:CLAUDE_INSTALLER_TEMP_TARGET',
    "if ([string]::IsNullOrWhiteSpace($filePath)) { throw 'Private temporary file target is missing' }",
    '$systemSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-18\')',
    '$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier(\'S-1-5-32-544\')',
    '$rights = [System.Security.AccessControl.FileSystemRights]::FullControl',
    '$allow = [System.Security.AccessControl.AccessControlType]::Allow',
    "if (-not [System.IO.File]::Exists($filePath)) { throw 'Private temporary file is missing' }",
    "if (([System.IO.File]::GetAttributes($filePath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Private temporary file is a reparse point' }",
    '$security = [System.IO.File]::GetAccessControl($filePath, [System.Security.AccessControl.AccessControlSections]::Access)',
    '$rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))',
    "if ($rules.Count -ne 2) { throw 'Private temporary file ACL has unexpected entries' }",
    "foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {",
    '  $matches = @($rules | Where-Object { $_.IdentityReference.Value -eq $sidValue })',
    "  if ($matches.Count -ne 1) { throw 'Private temporary file ACL identity is invalid' }",
    '  $rule = $matches[0]',
    "  if (-not $rule.IsInherited -or $rule.AccessControlType -ne $allow -or [int]$rule.FileSystemRights -ne [int]$rights) { throw 'Private temporary file ACL rule is invalid' }",
    '}',
  ].join('\n');
}

const CREATE_WINDOWS_PRIVATE_DIRECTORY = Buffer.from(createDirectorySecurityScript(), 'utf16le').toString('base64');
const VERIFY_WINDOWS_PRIVATE_DIRECTORY = Buffer.from(createVerifyDirectoryScript(), 'utf16le').toString('base64');
const VERIFY_WINDOWS_PRIVATE_FILE = Buffer.from(createVerifyFileScript(), 'utf16le').toString('base64');

function runWindowsPowerShell(encodedCommand, extraEnvironment) {
  const result = childProcess.spawnSync(WINDOWS_POWERSHELL, [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    encodedCommand,
  ], {
    encoding: 'utf8',
    env: Object.assign({}, WINDOWS_POWERSHELL_ENV, extraEnvironment),
    maxBuffer: 64 * 1024,
    shell: false,
    timeout: WINDOWS_POWERSHELL_TIMEOUT_MS,
    windowsHide: true,
  });

  if (result.error || result.signal || result.status !== 0) {
    throw new Error('Windows private temporary directory security check failed');
  }
}

function normalizeDirectory(directory) {
  const absolute = path.resolve(directory);
  return isWindows() ? absolute.toLowerCase() : absolute;
}

function directoryRecord(directory) {
  const key = normalizeDirectory(directory);
  const record = windowsDirectories.get(key);
  if (!record || record.directory !== key) {
    throw new Error('Temporary directory was not created by this process');
  }
  return record;
}

function isDirectChild(directory, candidate) {
  return path.dirname(path.resolve(candidate)) === path.resolve(directory);
}

function assertWindowsPrivateDirectory(directory) {
  const record = directoryRecord(directory);
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error('Temporary directory must be a non-link directory');
  }
  runWindowsPowerShell(VERIFY_WINDOWS_PRIVATE_DIRECTORY, {
    CLAUDE_INSTALLER_TEMP_TARGET: record.path,
  });
}

function assertPrivateDirectory(directory) {
  if (isWindows()) {
    assertWindowsPrivateDirectory(directory);
    return;
  }

  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error('Temporary directory must be a non-link directory');
  }
  if (isLinux() && (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700)) {
    throw new Error('Temporary directory owner or mode is insecure');
  }
}

function createWindowsTaskTempDir(label) {
  const name = `claude-installer-${label}-${crypto.randomBytes(16).toString('hex')}`;
  if (!WINDOWS_TEMP_NAME_RE.test(name)) {
    throw new Error('Windows private temporary directory name is invalid');
  }

  runWindowsPowerShell(CREATE_WINDOWS_PRIVATE_DIRECTORY, {
    CLAUDE_INSTALLER_TEMP_NAME: name,
  });

  const directory = path.join(WINDOWS_TEMP_PARENT, name);
  const key = normalizeDirectory(directory);
  const record = { directory: key, files: new Map(), path: directory };
  windowsDirectories.set(key, record);
  try {
    assertWindowsPrivateDirectory(directory);
    return directory;
  } catch (error) {
    windowsDirectories.delete(key);
    throw error;
  }
}

function createTaskTempDir(label) {
  assertSafeName(label);
  if (isWindows()) return createWindowsTaskTempDir(label);

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), `claude-installer-${label}-`));
  try {
    fs.chmodSync(directory, 0o700);
    assertPrivateDirectory(directory);
    return directory;
  } catch (error) {
    try { fs.rmdirSync(directory); } catch (_) {}
    throw error;
  }
}

function taskFile(directory, name) {
  assertPrivateDirectory(directory);
  assertSafeName(name);
  const filePath = path.join(directory, name);
  if (!isDirectChild(directory, filePath)) {
    throw new Error('Temporary file path escapes the task directory');
  }
  if (isWindows()) {
    const record = directoryRecord(directory);
    // Files receive the directory's inheritable protected DACL; retain their exact allocation.
    record.files.set(normalizeDirectory(filePath), filePath);
  }
  return filePath;
}

function assertWindowsPrivateFile(directory, filePath) {
  const record = directoryRecord(directory);
  const expectedPath = record.files.get(normalizeDirectory(filePath));
  if (!expectedPath || expectedPath !== filePath) {
    throw new Error('Temporary file was not allocated by this process');
  }
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error('Temporary file must be a regular non-link file');
  }
  runWindowsPowerShell(VERIFY_WINDOWS_PRIVATE_FILE, {
    CLAUDE_INSTALLER_TEMP_TARGET: expectedPath,
  });
}

function assertPrivateFile(directory, filePath) {
  assertPrivateDirectory(directory);
  if (!isDirectChild(directory, filePath)) {
    throw new Error('Temporary file path escapes the task directory');
  }
  if (isWindows()) {
    assertWindowsPrivateFile(directory, filePath);
    return;
  }

  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error('Temporary file must be a regular non-link file');
  }
  if (isLinux() && (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600)) {
    throw new Error('Temporary file owner or mode is insecure');
  }
}

function cleanupWindowsTaskTempDir(directory, files) {
  let record;
  try {
    record = directoryRecord(directory);
  } catch (_) {
    return;
  }

  try {
    assertWindowsPrivateDirectory(directory);
    (files || []).forEach((filePath) => {
      const expectedPath = record.files.get(normalizeDirectory(filePath));
      if (!expectedPath || expectedPath !== filePath) return;
      try {
        assertWindowsPrivateFile(directory, expectedPath);
        fs.unlinkSync(expectedPath);
        record.files.delete(normalizeDirectory(expectedPath));
      } catch (error) {
        if (!error || error.code !== 'ENOENT') throw error;
        record.files.delete(normalizeDirectory(expectedPath));
      }
    });
    fs.rmdirSync(directory);
    windowsDirectories.delete(record.directory);
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      windowsDirectories.delete(record.directory);
      return;
    }
    if (!error || error.code !== 'ENOTEMPTY') throw error;
  }
}

function cleanupTaskTempDir(directory, files) {
  if (isWindows()) {
    cleanupWindowsTaskTempDir(directory, files);
    return;
  }

  try {
    assertPrivateDirectory(directory);
    (files || []).forEach((filePath) => {
      if (!isDirectChild(directory, filePath)) return;
      try { fs.unlinkSync(filePath); } catch (error) {
        if (!error || error.code !== 'ENOENT') throw error;
      }
    });
    fs.rmdirSync(directory);
  } catch (error) {
    if (!error || error.code !== 'ENOENT' && error.code !== 'ENOTEMPTY') throw error;
  }
}

module.exports = { assertPrivateFile, cleanupTaskTempDir, createTaskTempDir, taskFile };
