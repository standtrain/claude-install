/**
 * 集中配置：内置安装脚本、Git 镜像、目标目录。
 */
module.exports = {
  INSTALL_SCRIPT: {
    name: '安装包内置 Windows 脚本',
    relativePath: 'deploy/cc-custom.ps1',
    sha256: 'b5e2d500394d0ce645caecdc47eb3e775a4a63bab4045a56f998353a287320e0',
  },
  GIT_MIRRORS: [
    {
      id: 'github',
      name: 'Git for Windows 官方 GitHub Releases',
      url: 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe',
      size: 69109976,
      sha256: '25527923debc06515b3016f2d6bca0820656e8281a23be2f43bfb658bd5dda70',
    },
    {
      id: 'ghproxy-git',
      name: 'GitHub 镜像加速 (ghproxy.com)',
      url: 'https://ghproxy.com/https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe',
      size: 69109976,
      sha256: '25527923debc06515b3016f2d6bca0820656e8281a23be2f43bfb658bd5dda70',
    },
    {
      id: 'mirror-ghproxy-git',
      name: 'GitHub 镜像加速 (mirror.ghproxy.com)',
      url: 'https://mirror.ghproxy.com/https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe',
      size: 69109976,
      sha256: '25527923debc06515b3016f2d6bca0820656e8281a23be2f43bfb658bd5dda70',
    },
  ],
  URL_WHITELIST: [
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'codeload.github.com',
    'storage.googleapis.com',
    'ghproxy.com',
    'mirror.ghproxy.com',
  ],

  INSTALL_ROOT: 'C:\\ProgramData\\claude',
  INSTALL_BIN_DIR: 'C:\\ProgramData\\claude\\bin',
  DOWNLOAD_TIMEOUT_MS: 8000,
  GIT_SETUP_ARGS: [
    '/VERYSILENT',
    '/NORESTART',
    '/NOCANCEL',
    '/SP-',
    '/SUPPRESSMSGBOXES',
    '/COMPONENTS=icons,ext\\reg\\shellhere,assoc,assoc_sh',
  ],
  // CC Switch —— Claude Code 供应商切换 GUI
  CCSWITCH: {
    // GitHub 镜像加速代理（自动派生：代理域名 + 原始 GitHub URL）
    ghMirrorProxies: [
      'https://ghproxy.com/',
      'https://mirror.ghproxy.com/',
    ],
    // 只接受经过离线审查的固定版本、大小与 SHA256。
    pinned: {
      version: 'v3.18.0',
      url: 'https://github.com/farion1231/cc-switch/releases/download/v3.18.0/CC-Switch-v3.18.0-Windows.msi',
      sha256: 'c4a6eaf763269396f90a81377381e91c8341538b51376912c81bab73e844612d',
      size: 12849152,
    },
  },
};
