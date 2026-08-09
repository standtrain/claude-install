/**
 * 集中配置：Linux 安装路径、内置安装脚本与下载源。
 */
module.exports = {
  // ── 安装目标路径 ──
  INSTALL_ROOT: '/opt/claude',
  INSTALL_BIN_DIR: '/opt/claude/bin',
  GLOBAL_BIN_DIR: '/usr/local/bin',
  GLOBAL_CLAUDE_LINK: '/usr/local/bin/claude',

  INSTALL_SCRIPT: {
    name: '安装包内置 Linux 脚本',
    relativePath: 'deploy/cc-custom.sh',
    sha256: '433ddf293630c0300d8af6923db0cb08c214f054c3e2c5d3a8f2bca0b59d02ce',
  },
  CCSWITCH_SCRIPT: {
    name: '安装包内置 CC Switch 脚本',
    relativePath: 'deploy/ccswitch.sh',
    sha256: '5c52518bf6364213fc670e52f4a2dc464d1c943d5e9319e6f437e196b81a7ec3',
  },

  // ── Git 包管理器方案（Linux 非必要，仅兜底） ──
  GIT_PACKAGES: [
    { name: 'apt', executable: '/usr/bin/apt-get', args: ['install', '-y', 'git'] },
    { name: 'dnf', executable: '/usr/bin/dnf', args: ['install', '-y', 'git'] },
    { name: 'yum', executable: '/usr/bin/yum', args: ['install', '-y', 'git'] },
    { name: 'pacman', executable: '/usr/bin/pacman', args: ['-S', '--noconfirm', 'git'] },
    { name: 'zypper', executable: '/usr/bin/zypper', args: ['install', '-y', 'git'] },
  ],
};
