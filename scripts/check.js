#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '..');

function fail(message) {
  console.error(`[check] ${message}`);
  process.exitCode = 1;
}

function walk(directory, extension, result) {
  fs.readdirSync(directory).sort().forEach((name) => {
    const fullPath = path.join(directory, name);
    const stat = fs.lstatSync(fullPath);
    if (stat.isSymbolicLink()) {
      fail(`${path.relative(root, fullPath)}: 源码目录禁止使用符号链接`);
      return;
    }
    if (stat.isDirectory()) walk(fullPath, extension, result);
    else if (fullPath.endsWith(extension)) result.push(fullPath);
  });
}

function run(executable, args, label) {
  const result = spawnSync(executable, args, {
    cwd: root,
    encoding: 'utf8',
    shell: false,
    windowsHide: true,
  });
  if (result.error) {
    fail(`${label} 无法启动：${result.error.message}`);
    return false;
  }
  if (result.signal) {
    fail(`${label} 被信号中止：${result.signal}`);
    return false;
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    fail(`${label} 失败${detail ? `：${detail}` : `，退出码 ${result.status}`}`);
    return false;
  }
  return true;
}

const jsFiles = [];
walk(path.join(root, 'src'), '.js', jsFiles);
walk(path.join(root, 'linux-installer', 'src'), '.js', jsFiles);
walk(path.join(root, 'scripts'), '.js', jsFiles);
walk(path.join(root, 'tests'), '.js', jsFiles);
jsFiles.forEach((file) => run(process.execPath, ['--check', file], path.relative(root, file)));

const forbiddenJs = [
  { pattern: /require\(['"]node:/, label: 'Node 11 不支持的 node: 导入' },
  { pattern: /\?\?/, label: 'Node 11 不支持的空值合并语法' },
  { pattern: /\?\.(?!\d)/, label: 'Node 11 不支持的可选链语法' },
  { pattern: /shell\s*:\s*true/, label: '禁止 shell:true' },
  { pattern: /\.innerHTML\s*=/, label: '禁止动态 innerHTML' },
];
jsFiles.forEach((file) => {
  if (path.resolve(file) === path.resolve(__filename)) return;
  const source = fs.readFileSync(file, 'utf8');
  forbiddenJs.forEach((rule) => {
    if (rule.pattern.test(source)) fail(`${path.relative(root, file)}: ${rule.label}`);
  });
});

const deployFiles = ['cc-custom.sh', 'ccswitch.sh', 'cc-custom.ps1', 'ccswitch.ps1'];
deployFiles.forEach((name) => {
  const source = fs.readFileSync(path.join(root, 'deploy', name), 'utf8');
  if (/http:\/\//i.test(source)) fail(`deploy/${name}: 禁止明文 HTTP 下载`);
  if (/PLACEHOLDER/i.test(source)) fail(`deploy/${name}: 存在占位配置`);
});

const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const expectedEngines = { node: '11.9.x', npm: '6.x' };
if (!packageJson.engines
    || packageJson.engines.node !== expectedEngines.node
    || packageJson.engines.npm !== expectedEngines.npm) {
  fail('package.json 必须锁定 Node 11.9.x 与 npm 6.x');
}
if (packageJson.devDependencies.electron !== '21.4.4'
    || packageJson.devDependencies['electron-builder'] !== '22.10.5') {
  fail('Electron 构建版本未锁定到 Node 11.9 兼容组合');
}

const linuxPackage = JSON.parse(
  fs.readFileSync(path.join(root, 'linux-installer', 'package.json'), 'utf8'),
);
if (fs.existsSync(path.join(root, 'linux-installer', 'package-lock.json'))) {
  fail('Linux 子项目禁止维护独立 package-lock，请统一使用根锁文件');
}
if (linuxPackage.version !== packageJson.version) fail('Linux 安装器版本必须与根项目一致');
if (!linuxPackage.engines
    || linuxPackage.engines.node !== expectedEngines.node
    || linuxPackage.engines.npm !== expectedEngines.npm) {
  fail('Linux 安装器必须锁定 Node 11.9.x 与 npm 6.x');
}
['electron', 'electron-builder'].forEach((dependency) => {
  if (!linuxPackage.devDependencies
      || linuxPackage.devDependencies[dependency] !== packageJson.devDependencies[dependency]) {
    fail(`Linux 安装器的 ${dependency} 版本必须与根项目一致`);
  }
});

const lockPath = path.join(root, 'package-lock.json');
if (!fs.existsSync(lockPath)) {
  fail('缺少 package-lock.json，无法复现构建');
} else {
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  if (lock.name !== packageJson.name || lock.version !== packageJson.version) fail('package-lock 顶层元数据不一致');
  if (lock.lockfileVersion !== 1) fail('package-lock 必须由 Node 11 自带的 npm 6 生成（lockfileVersion 1）');
  ['electron', 'electron-builder'].forEach((dependency) => {
    const locked = lock.dependencies && lock.dependencies[dependency];
    if (!locked || locked.version !== packageJson.devDependencies[dependency]) {
      fail(`package-lock 中的 ${dependency} 版本与 package.json 不一致`);
    }
  });
}

const shellCandidates = process.platform === 'win32'
  ? [path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe')]
  : ['/bin/sh'];
if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
  shellCandidates.push(path.join(process.env.LOCALAPPDATA, 'Programs', 'Git', 'bin', 'bash.exe'));
}
const shell = shellCandidates.find((candidate) => candidate && fs.existsSync(candidate));
if (shell) {
  run(shell, ['-n', path.join(root, 'deploy', 'cc-custom.sh')], 'cc-custom.sh 语法检查');
  run(shell, ['-n', path.join(root, 'deploy', 'ccswitch.sh')], 'ccswitch.sh 语法检查');
} else {
  fail('未找到可用于 shell -n 的解释器');
}

if (process.platform === 'win32') {
  const files = ['cc-custom.ps1', 'ccswitch.ps1'].map((name) => path.join(root, 'deploy', name));
  const quoted = files.map((file) => `'${file.replace(/'/g, "''")}'`).join(',');
  const command = `$files=@(${quoted});$bad=$false;foreach($file in $files){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);if($errors.Count){$bad=$true;$errors|ForEach-Object{Write-Error $_.Message}}};if($bad){exit 1}`;
  const encoded = Buffer.from(command, 'utf16le').toString('base64');
  const powershell = path.join(
    process.env.SystemRoot || 'C:\\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  run(powershell, ['-NoLogo', '-NoProfile', '-EncodedCommand', encoded], 'PowerShell 5.1 AST 检查');
}

if (process.exitCode) process.exit(process.exitCode);
console.log(`[check] 通过：${jsFiles.length} 个 JavaScript 文件及 4 个部署脚本`);
