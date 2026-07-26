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
    sha256: '0b90e639864df9ffe7082d27a9ff8b71f129f7192fbc58472db35b1a057712a0',
  },
  CCSWITCH_SCRIPT: {
    name: '安装包内置 CC Switch 脚本',
    relativePath: 'deploy/ccswitch.sh',
    sha256: '6bf6ac4159bb680055f68a0043df62902cb510c15435b3e797c296083d28c648',
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
