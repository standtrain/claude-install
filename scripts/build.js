#!/usr/bin/env node
/**
 * 单一构建入口：node scripts/build.js <win|linux> [target] [x64|arm64]
 */
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const cliArgs = process.argv.slice(2);
const platform = cliArgs[0] || 'win';
const target = cliArgs[1] || '';
const architecture = cliArgs[2] || '';
const allowedTargets = {
  win: ['', 'portable', 'nsis'],
  linux: ['', 'AppImage', 'deb', 'rpm'],
};
const allowedArchitectures = {
  win: ['', 'x64'],
  linux: ['', 'x64', 'arm64'],
};

if (cliArgs.length > 3
    || !Object.prototype.hasOwnProperty.call(allowedTargets, platform)
    || allowedTargets[platform].indexOf(target) === -1
    || allowedArchitectures[platform].indexOf(architecture) === -1) {
  console.error('用法: node scripts/build.js <win|linux> [portable|nsis|AppImage|deb|rpm] [x64|arm64]');
  process.exit(2);
}

const projectDir = platform === 'linux' ? path.join(rootDir, 'linux-installer') : rootDir;
const configPath = path.join(projectDir, 'electron-builder.yml');
const builderCli = path.join(rootDir, 'node_modules', 'electron-builder', 'out', 'cli', 'cli.js');

function readJson(filePath, label) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    console.error(`[build] ${label} 无法读取：${error.message}`);
    process.exit(1);
    return null;
  }
}

const rootPackage = readJson(path.join(rootDir, 'package.json'), 'package.json');
const expectedVersions = rootPackage.devDependencies || {};
if (platform === 'linux') {
  const linuxPackage = readJson(path.join(projectDir, 'package.json'), 'linux-installer/package.json');
  if (linuxPackage.version !== rootPackage.version) {
    console.error('[build] Linux 安装器版本与根项目不一致');
    process.exit(1);
  }
  ['electron', 'electron-builder'].forEach((dependency) => {
    if (!linuxPackage.devDependencies
        || linuxPackage.devDependencies[dependency] !== expectedVersions[dependency]) {
      console.error(`[build] Linux 安装器的 ${dependency} 版本与根项目不一致`);
      process.exit(1);
    }
  });
}
['electron', 'electron-builder'].forEach((dependency) => {
  const installedManifest = path.join(rootDir, 'node_modules', dependency, 'package.json');
  if (!fs.existsSync(installedManifest)) {
    console.error(`[build] ${dependency} 未安装，请先使用 Node 11.9 和 npm 6 执行 npm ci`);
    process.exit(1);
  }
  const installed = readJson(installedManifest, `${dependency}/package.json`);
  if (installed.version !== expectedVersions[dependency]) {
    console.error(
      `[build] ${dependency} 版本不一致：期望 ${expectedVersions[dependency]}，实际 ${installed.version}；请重新执行 npm ci`,
    );
    process.exit(1);
  }
});

if (!fs.existsSync(builderCli) || !fs.statSync(builderCli).isFile()) {
  console.error(`[build] electron-builder 入口不存在：${builderCli}`);
  process.exit(1);
}
if (!fs.existsSync(configPath) || !fs.statSync(configPath).isFile()) {
  console.error(`构建配置不存在：${configPath}`);
  process.exit(1);
}

const buildTime = new Date().toISOString();
const buildArchitectures = platform === 'linux' && target === 'AppImage' && !architecture
  ? ['x64', 'arm64']
  : [architecture];

for (const buildArchitecture of buildArchitectures) {
  const args = [builderCli, `--${platform}`];
  if (target) args.push(target);
  if (buildArchitecture) args.push(`--${buildArchitecture}`);
  args.push('--projectDir', projectDir, '--config', configPath);
  args.push(`-c.extraMetadata.buildTime=${buildTime}`);

  console.log(`[build] platform=${platform} target=${target || 'all'} arch=${buildArchitecture || 'default'} buildTime=${buildTime}`);
  const result = spawnSync(process.execPath, args, {
    cwd: rootDir,
    stdio: 'inherit',
    env: process.env,
    shell: false,
    windowsHide: true,
  });

  if (result.error) {
    console.error(`[build] 启动失败：${result.error.message}`);
    process.exit(1);
  }
  if (result.signal) {
    console.error(`[build] 被信号中止：${result.signal}`);
    process.exit(1);
  }
  const status = Number.isInteger(result.status) ? result.status : 1;
  if (status !== 0) process.exit(status);
}

if (platform === 'linux' && (target === '' || target === 'AppImage')) {
  const { createExecutableAppImageArchive } = require('./appimageArchive');
  const architectures = architecture ? [architecture] : ['x64', 'arm64'];
  Promise.all(architectures.map((arch) => {
    const artifactArch = arch === 'x64' ? 'x86_64' : arch;
    const appImage = path.join(
      projectDir,
      'dist',
      `ClaudeCLIInstaller-Linux-${rootPackage.version}-${artifactArch}.AppImage`,
    );
    return createExecutableAppImageArchive(appImage, `${appImage}.tar.gz`).then((archive) => {
      console.log(`[build] executable AppImage archive=${archive}`);
    });
  })).catch((error) => {
    console.error(`[build] AppImage 可执行归档失败：${error.message}`);
    process.exitCode = 1;
  });
}
