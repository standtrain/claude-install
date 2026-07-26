const logger = require('../logger');
const { run } = require('./bundledScript');

async function install(metadata, installer) {
  logger.step('执行安装包内置 Claude 安装脚本');
  await run(metadata, 'Claude 安装脚本', installer);
}

module.exports = { install };
