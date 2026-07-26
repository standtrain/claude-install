const env = require('../env');
const logger = require('../logger');
const { run } = require('./bundledScript');

async function install() {
  logger.step('执行安装包内置 CC Switch 安装脚本');
  await run(env.CCSWITCH_SCRIPT, 'CC Switch 安装脚本');
  logger.ok('CC Switch 安装完成');
}

module.exports = { install };
