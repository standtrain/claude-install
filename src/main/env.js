/**
 * 集中配置：内置安装脚本、Git 镜像、目标目录。
 */
const GIT_VERSION = '2.55.0.windows.3';
const GIT_FILENAME = 'Git-2.55.0.3-64-bit.exe';
const GIT_SIZE = 65388144;
const GIT_SHA256 = 'af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca';

module.exports = {
  INSTALL_SCRIPT: {
    name: '安装包内置 Windows 脚本',
    relativePath: 'deploy/cc-custom.ps1',
    sha256: '39af7c26fa910d393652f95dae08f57e7585d5634c85cb6990ca3c3b56b6127f',
  },
  GIT_MIRRORS: [
    {
      id: 'github',
      name: 'Git for Windows 官方 GitHub Releases',
      url: `https://github.com/git-for-windows/git/releases/download/v${GIT_VERSION}/${GIT_FILENAME}`,
      size: GIT_SIZE,
      sha256: GIT_SHA256,
    },
    {
      id: 'tuna-git',
      name: '清华大学 TUNA GitHub Release 镜像',
      url: `https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/Git%20for%20Windows%202.55.0%283%29/${GIT_FILENAME}`,
      size: GIT_SIZE,
      sha256: GIT_SHA256,
    },
    {
      id: 'npmmirror-git',
      name: '阿里云 CDN (npmmirror)',
      url: `https://registry.npmmirror.com/-/binary/git-for-windows/v${GIT_VERSION}/${GIT_FILENAME}`,
      size: GIT_SIZE,
      sha256: GIT_SHA256,
    },
    {
      id: 'huawei-git',
      name: '华为云 Git for Windows 镜像',
      url: `https://mirrors.huaweicloud.com/git-for-windows/v${GIT_VERSION}/${GIT_FILENAME}`,
      size: GIT_SIZE,
      sha256: GIT_SHA256,
    },
  ],
  URL_WHITELIST: [
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'codeload.github.com',
    'storage.googleapis.com',
    'mirrors.tuna.tsinghua.edu.cn',
    'registry.npmmirror.com',
    'cdn.npmmirror.com',
    'mirrors.huaweicloud.com',
    'ghproxy.net',
    'gh-proxy.com',
    'ghfast.top',
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
      { name: 'ghproxy.net', url: 'https://ghproxy.net/' },
      { name: 'gh-proxy.com', url: 'https://gh-proxy.com/' },
      { name: 'ghfast.top', url: 'https://ghfast.top/' },
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
