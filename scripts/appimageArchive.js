/**
 * Create a tar.gz sidecar that preserves the AppImage executable bit.
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { pipeline } = require('stream');

const TAR_BLOCK_SIZE = 512;
const MAX_APPIMAGE_BYTES = 1024 * 1024 * 1024;

function writeString(buffer, offset, length, value) {
  const bytes = Buffer.from(value, 'ascii');
  if (bytes.length > length) throw new Error('tar 字段长度超出限制');
  bytes.copy(buffer, offset);
}

function writeOctal(buffer, offset, length, value) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('tar 数值字段无效');
  const octal = value.toString(8);
  if (octal.length > length - 1) throw new Error('tar 数值字段超出限制');
  writeString(buffer, offset, length, `${'0'.repeat(length - 1 - octal.length)}${octal}\0`);
}

function createHeader(name, size, mtimeSeconds) {
  if (!/^[A-Za-z0-9._-]{1,100}$/.test(name)) throw new Error('AppImage 归档文件名无效');

  const header = Buffer.alloc(TAR_BLOCK_SIZE, 0);
  writeString(header, 0, 100, name);
  writeOctal(header, 100, 8, 0o755);
  writeOctal(header, 108, 8, 0);
  writeOctal(header, 116, 8, 0);
  writeOctal(header, 124, 12, size);
  writeOctal(header, 136, 12, mtimeSeconds);
  header.fill(0x20, 148, 156);
  writeString(header, 156, 1, '0');
  writeString(header, 257, 6, 'ustar\0');
  writeString(header, 263, 2, '00');
  writeString(header, 265, 32, 'root');
  writeString(header, 297, 32, 'root');

  let checksum = 0;
  for (let index = 0; index < header.length; index += 1) checksum += header[index];
  const checksumValue = checksum.toString(8);
  if (checksumValue.length > 6) throw new Error('tar 校验和超出限制');
  writeString(header, 148, 8, `${'0'.repeat(6 - checksumValue.length)}${checksumValue}\0 `);
  return header;
}

function assertAppImage(filePath) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 64 || stat.size > MAX_APPIMAGE_BYTES) {
    throw new Error('AppImage 文件大小或类型无效');
  }

  const fd = fs.openSync(filePath, 'r');
  try {
    const header = Buffer.alloc(12);
    if (fs.readSync(fd, header, 0, header.length, 0) !== header.length
        || header.slice(0, 4).toString('hex') !== '7f454c46'
        || header.slice(8, 11).toString('hex') !== '414902') {
      throw new Error('文件不是有效的 AppImage Type 2');
    }
  } finally {
    fs.closeSync(fd);
  }
  return stat;
}

function writeTar(inputPath, tarPath, stat) {
  const inputFd = fs.openSync(inputPath, 'r');
  let outputFd = null;
  try {
    outputFd = fs.openSync(tarPath, 'wx', 0o600);
    fs.writeSync(outputFd, createHeader(path.basename(inputPath), stat.size, Math.floor(stat.mtimeMs / 1000)));
    const buffer = Buffer.alloc(128 * 1024);
    let total = 0;
    while (total < stat.size) {
      const bytesRead = fs.readSync(inputFd, buffer, 0, Math.min(buffer.length, stat.size - total), total);
      if (bytesRead <= 0) throw new Error('读取 AppImage 时连接意外中断');
      fs.writeSync(outputFd, buffer, 0, bytesRead);
      total += bytesRead;
    }
    const padding = (TAR_BLOCK_SIZE - (stat.size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE;
    if (padding) fs.writeSync(outputFd, Buffer.alloc(padding));
    fs.writeSync(outputFd, Buffer.alloc(TAR_BLOCK_SIZE * 2));
  } finally {
    fs.closeSync(inputFd);
    if (outputFd !== null) fs.closeSync(outputFd);
  }
}

function createExecutableAppImageArchive(inputPath, outputPath) {
  const input = path.resolve(inputPath);
  const output = path.resolve(outputPath);
  if (input === output || path.dirname(input) !== path.dirname(output)
      || output !== `${input}.tar.gz`) {
    return Promise.reject(new Error('AppImage 归档输出路径无效'));
  }

  let stat;
  try {
    stat = assertAppImage(input);
  } catch (error) {
    return Promise.reject(error);
  }

  const token = `${process.pid}-${Date.now()}`;
  const tarPath = `${output}.tar-${token}`;
  const partPath = `${output}.part-${token}`;
  try {
    writeTar(input, tarPath, stat);
  } catch (error) {
    try { fs.unlinkSync(tarPath); } catch (_) {}
    return Promise.reject(error);
  }

  return new Promise((resolve, reject) => {
    pipeline(
      fs.createReadStream(tarPath),
      zlib.createGzip({ level: 9 }),
      fs.createWriteStream(partPath, { flags: 'wx', mode: 0o600 }),
      (error) => {
        try { fs.unlinkSync(tarPath); } catch (_) {}
        if (error) {
          try { fs.unlinkSync(partPath); } catch (_) {}
          reject(error);
          return;
        }
        try {
          if (fs.existsSync(output)) fs.unlinkSync(output);
          fs.renameSync(partPath, output);
          resolve(output);
        } catch (renameError) {
          try { fs.unlinkSync(partPath); } catch (_) {}
          reject(renameError);
        }
      },
    );
  });
}

module.exports = { createExecutableAppImageArchive };
