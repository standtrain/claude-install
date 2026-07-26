#!/usr/bin/env node
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const zlib = require('zlib');

if (process.platform === 'win32') {
  process.env.LOCALAPPDATA = process.env.CCP_TEST_TMPDIR || os.tmpdir();
}

const tests = [];
function test(name, handler) { tests.push({ name, handler }); }

function expectReject(promise, pattern) {
  return promise.then(
    () => { throw new Error('期望 Promise 失败，但实际成功'); },
    (error) => {
      if (pattern) assert(pattern.test(String(error && error.message ? error.message : error)));
    },
  );
}

function removeTree(target) {
  if (!fs.existsSync(target)) return;
  const stat = fs.lstatSync(target);
  if (!stat.isDirectory() || stat.isSymbolicLink()) { fs.unlinkSync(target); return; }
  fs.readdirSync(target).forEach((name) => removeTree(path.join(target, name)));
  fs.rmdirSync(target);
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function close(server) { return new Promise((resolve) => server.close(resolve)); }

async function downloaderSuite(label, modulePath, envPath) {
  const downloader = require(modulePath);
  const env = require(envPath);
  const payload = Buffer.from('MZ trusted test payload', 'utf8');
  const tempRoot = process.env.CCP_TEST_TMPDIR || os.tmpdir();
  const temp = fs.mkdtempSync(path.join(tempRoot, 'claude-installer-test-'));
  const server = http.createServer((req, res) => {
    if (req.url === '/json-redirect') {
      res.writeHead(302, { Location: '/json' });
      res.end();
    } else if (req.url === '/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    } else if (req.url === '/bad-redirect') {
      res.writeHead(302, { Location: `http://localhost:${server.address().port}/json` });
      res.end();
    } else if (req.url === '/missing') {
      res.writeHead(404);
      res.end('missing');
    } else if (req.url === '/large') {
      res.writeHead(200, { 'Content-Length': '100' });
      res.end(Buffer.alloc(100, 1));
    } else if (req.url === '/slow') {
      res.writeHead(200, { 'Content-Length': '100' });
      res.write(Buffer.alloc(1, 1));
      setTimeout(() => res.end(Buffer.alloc(99, 1)), 150);
    } else {
      res.writeHead(200, { 'Content-Length': String(payload.length) });
      res.end(payload);
    }
  });
  const port = await listen(server);
  const allowedHost = `127.0.0.1:${port}`;
  env.URL_WHITELIST.push(allowedHost);
  const base = `http://${allowedHost}`;
  try {
    assert.strictEqual(downloader.isAllowed(`${base}/file`), true);
    assert.strictEqual(downloader.isAllowed('http://github.com/file'), false);
    assert.strictEqual(downloader.isAllowed('https://attacker.github.com/file'), false);
    assert.strictEqual(downloader.isAllowed(`http://localhost:${port}/file`), false);
    assert.strictEqual(downloader.isAllowed(`http://user:pass@${allowedHost}/file`), false);
    assert.strictEqual(downloader.isAllowed('file:///tmp/payload'), false);

    const json = await downloader.readJson(`${base}/json-redirect`);
    assert.deepStrictEqual(json, { ok: true });
    await expectReject(downloader.readJson(`${base}/bad-redirect`), /允许范围/);

    const ranked = await downloader.speedTest([
      { id: 'ok', url: `${base}/file` },
      { id: 'missing', url: `${base}/missing` },
    ]);
    assert.strictEqual(ranked.find((entry) => entry.id === 'ok').ok, true);
    assert.strictEqual(ranked.find((entry) => entry.id === 'missing').ok, false);

    const destination = path.join(temp, 'payload.bin');
    await downloader.download(`${base}/file`, destination, null, null, { maxBytes: 1024 });
    assert.deepStrictEqual(fs.readFileSync(destination), payload);
    const expectedHash = crypto.createHash('sha256').update(payload).digest('hex');
    assert.strictEqual(await downloader.sha256File(destination), expectedHash);

    const tooLarge = path.join(temp, 'too-large.bin');
    await expectReject(
      downloader.download(`${base}/large`, tooLarge, null, null, { maxBytes: 10 }),
      /大小限制/,
    );
    assert.strictEqual(fs.existsSync(tooLarge), false);

    const cancelled = path.join(temp, 'cancelled.bin');
    const controller = downloader.createAbortController();
    const pending = downloader.download(`${base}/slow`, cancelled, null, controller.signal, { maxBytes: 1024 });
    setTimeout(() => controller.abort(), 20);
    await expectReject(pending, /取消/);
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.strictEqual(fs.existsSync(cancelled), false);
    assert.strictEqual(fs.readdirSync(temp).some((name) => name.indexOf('.part-') !== -1), false);
  } finally {
    const index = env.URL_WHITELIST.indexOf(allowedHost);
    if (index !== -1) env.URL_WHITELIST.splice(index, 1);
    await close(server);
    removeTree(temp);
  }
  console.log(`[test] ${label} 下载器行为通过`);
}

test('Windows downloader', () => downloaderSuite(
  'Windows',
  path.join(__dirname, '..', 'src', 'main', 'installer', 'downloader'),
  path.join(__dirname, '..', 'src', 'main', 'env'),
));

test('Windows Git mirrors pin the latest verified release', () => {
  const root = path.join(__dirname, '..');
  const env = require(path.join(root, 'src', 'main', 'env'));
  const downloader = require(path.join(root, 'src', 'main', 'installer', 'downloader'));
  const expectedIds = ['github', 'tuna-git', 'npmmirror-git', 'huawei-git'];
  const ids = env.GIT_MIRRORS.map((source) => source.id);

  assert.deepStrictEqual(ids, expectedIds);
  assert.strictEqual(new Set(ids).size, ids.length);
  env.GIT_MIRRORS.forEach((source) => {
    assert(/2\.55\.0/.test(source.url));
    assert.strictEqual(source.size, 65388144);
    assert.strictEqual(source.sha256, 'af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca');
    assert.strictEqual(downloader.isAllowed(source.url), true);
  });
  assert(env.URL_WHITELIST.includes('cdn.npmmirror.com'));
});

test('Windows config verification safety', () => {
  const tempRoot = process.env.CCP_TEST_TMPDIR || os.tmpdir();
  const temp = fs.mkdtempSync(path.join(tempRoot, 'claude-config-test-'));
  const configPath = path.join(__dirname, '..', 'src', 'main', 'installer', 'configWriter');
  const loggerPath = path.join(__dirname, '..', 'src', 'main', 'logger');
  const resolvedConfig = require.resolve(configPath);
  const resolvedLogger = require.resolve(loggerPath);
  const originalLoggerCache = require.cache[resolvedLogger];
  const originalHomedir = os.homedir;

  require.cache[resolvedLogger] = {
    id: resolvedLogger,
    filename: resolvedLogger,
    loaded: true,
    exports: { info: () => {}, ok: () => {} },
  };
  delete require.cache[resolvedConfig];
  os.homedir = () => temp;
  try {
    const writer = require(configPath);
    const target = path.join(temp, '.claude.json');
    fs.writeFileSync(target, '{"existing":true,"hasCompletedOnboarding":true}\n', 'utf8');
    writer.verify();

    fs.writeFileSync(target, '{invalid', 'utf8');
    assert.throws(() => writer.verify(), /不是有效 JSON/);
    assert.strictEqual(fs.readFileSync(target, 'utf8'), '{invalid');

    fs.writeFileSync(target, '{"existing":true}\n', 'utf8');
    assert.throws(() => writer.verify(), /hasCompletedOnboarding/);

    fs.unlinkSync(target);
    fs.mkdirSync(target);
    assert.throws(() => writer.verify(), /普通文件/);
  } finally {
    os.homedir = originalHomedir;
    delete require.cache[resolvedConfig];
    if (originalLoggerCache) require.cache[resolvedLogger] = originalLoggerCache;
    else delete require.cache[resolvedLogger];
    removeTree(temp);
  }
});

test('Windows privileged command and CC Switch pinning contracts', async () => {
  const root = path.join(__dirname, '..');
  const system = require(path.join(root, 'src', 'main', 'installer', 'windowsSystem'));
  Object.keys(system.EXECUTABLES).forEach((key) => {
    assert(/^C:\\Windows\\System32\\[^\\]+\.exe$/i.test(system.EXECUTABLES[key]));
  });
  const options = system.systemOptions();
  assert.strictEqual(options.shell, false);
  assert.strictEqual(options.cwd, 'C:\\Windows\\System32');
  assert.strictEqual(options.env.PATH, 'C:\\Windows\\System32;C:\\Windows');

  const switchEnv = require(path.join(root, 'src', 'main', 'env')).CCSWITCH;
  const switchInstallerPath = path.join(root, 'src', 'main', 'installer', 'ccswitch');
  const switchInstaller = require(switchInstallerPath);
  const sources = await switchInstaller.buildSources();
  assert.strictEqual(sources.length, 4);
  sources.forEach((source) => {
    assert.strictEqual(source.version, switchEnv.pinned.version);
    assert.strictEqual(source.size, switchEnv.pinned.size);
    assert.strictEqual(source.sha256, switchEnv.pinned.sha256);
  });
  assert.deepStrictEqual(
    sources.slice(1).map((source) => new URL(source.url).hostname),
    ['gh-proxy.com', 'ghproxy.net', 'ghfast.top'],
  );
  const switchSource = fs.readFileSync(`${switchInstallerPath}.js`, 'utf8');
  assert(!/readJson|releases\/latest|githubApi/.test(switchSource));
  assert(/EXECUTABLES\.msiexec/.test(switchSource));
});

test('PowerShell web bootstrap contracts', () => {
  const deployRoot = path.join(__dirname, '..', 'deploy');
  ['cc-custom.ps1', 'ccswitch.ps1'].forEach((name) => {
    const bytes = fs.readFileSync(path.join(deployRoot, name));
    assert(bytes.length > 3);
    assert.notDeepStrictEqual(Array.from(bytes.slice(0, 3)), [0xef, 0xbb, 0xbf]);

    const source = bytes.toString('utf8');
    assert(/^#requires -Version 5\.1/i.test(source));
    assert(/function Assert-Administrator/.test(source));
    assert(/WindowsBuiltInRole\]::Administrator/.test(source));
    const invocation = source.indexOf('\nAssert-Administrator\n');
    const firstNetworkOperation = source.search(/Invoke-(?:RestMethod|WebRequest)|\.GetResponse\(/);
    const firstDirectoryMutation = source.search(/Directory\]::CreateDirectory|New-Item/);
    assert(invocation > 0);
    assert(firstNetworkOperation === -1 || invocation < firstNetworkOperation);
    assert(firstDirectoryMutation === -1 || invocation < firstDirectoryMutation);
  });

  const claudeSource = fs.readFileSync(path.join(deployRoot, 'cc-custom.ps1'), 'utf8');
  assert(/ReadAndExecute\s+-bor\s+`\s*\r?\n\s*\[System\.Security\.AccessControl\.FileSystemRights\]::Synchronize/.test(
    claudeSource,
  ));
});

test('renderers expose one CC Switch action', () => {
  const root = path.join(__dirname, '..');
  ['src', 'linux-installer/src'].forEach((rendererRoot) => {
    const renderer = path.join(root, rendererRoot, 'renderer');
    const html = fs.readFileSync(path.join(renderer, 'index.html'), 'utf8');
    const source = fs.readFileSync(path.join(renderer, 'app.js'), 'utf8');

    assert.strictEqual((html.match(/id="btn-ccswitch"/g) || []).length, 1);
    assert(!/btn-ccswitch-only/.test(html));
    assert(!/btnCCSwitchOnly|ccSwitchLabels/.test(source));
    assert(!/btnCCSwitch\.classList\.remove\(['"]hidden['"]\)/.test(source));
    assert.strictEqual((source.match(/btnCCSwitch\.addEventListener\(['"]click['"]/g) || []).length, 1);
  });
});

test('Linux target user and verification contracts', async () => {
  const installerRoot = path.join(__dirname, '..', 'linux-installer', 'src', 'main');
  const configWriter = require(path.join(installerRoot, 'installer', 'configWriter'));
  const pathManager = require(path.join(installerRoot, 'installer', 'pathManager'));
  const env = require(path.join(installerRoot, 'env'));
  const entries = [
    ['root', 'x', '0', '0', 'root', '/root', '/bin/bash'],
    ['alice', 'x', '1000', '1000', 'Alice', '/home/alice', '/bin/bash'],
  ];

  assert.deepStrictEqual(
    configWriter.resolveTargetUserFromEntries(entries, { SUDO_USER: 'alice' }, 0),
    { name: 'alice', uid: 1000, gid: 1000, home: '/home/alice' },
  );
  assert.throws(
    () => configWriter.resolveTargetUserFromEntries(entries, { SUDO_USER: 'missing' }, 0),
    /SUDO_USER 指定的用户不存在/,
  );
  assert.throws(
    () => configWriter.resolveTargetUserFromEntries(entries, { PKEXEC_UID: '2000' }, 0),
    /PKEXEC_UID 指定的用户不存在/,
  );
  assert.strictEqual(env.GLOBAL_CLAUDE_LINK, '/usr/local/bin/claude');
  assert.strictEqual(
    pathManager.resolvedLinkTarget('/usr/local/bin/claude', '../../../opt/claude/bin/claude'),
    '/opt/claude/bin/claude',
  );
  assert.strictEqual(typeof configWriter.verify, 'function');
  const configWriterSource = fs.readFileSync(
    path.join(installerRoot, 'installer', 'configWriter.js'),
    'utf8',
  );
  assert(/O_NOFOLLOW/.test(configWriterSource));
  assert(/fstatSync\(fd\)/.test(configWriterSource));
  assert(/stat\.uid !== owner\.uid/.test(configWriterSource));
  assert(/\(stat\.mode & 0o777\) !== 0o600/.test(configWriterSource));
  assert(/hasCompletedOnboarding !== true/.test(configWriterSource));

  const linuxSources = [
    fs.readFileSync(path.join(installerRoot, 'env.js'), 'utf8'),
    fs.readFileSync(path.join(installerRoot, 'installer', 'pathManager.js'), 'utf8'),
    fs.readFileSync(path.join(installerRoot, 'installer', 'detect.js'), 'utf8'),
  ].join('\n');
  assert(!/PROFILE_D_PATH|\/etc\/profile\.d/.test(linuxSources));

});

test('logger redaction contracts', () => {
  const root = path.join(__dirname, '..');
  const loggers = [
    require(path.join(root, 'src', 'main', 'logger')),
    require(path.join(root, 'linux-installer', 'src', 'main', 'logger')),
  ];
  const syntheticPrivateIp = ['192', '168', '1', '20'].join('.');
  const sensitiveInput = [
    'Authorization: Bearer auth1',
    'Proxy-Authorization=Basic YQ==',
    'upstream uses Bearer b2',
    'Cookie: sid=c3; theme=dark',
    'Set-Cookie: session=d4; Path=/; HttpOnly',
    'password=pass5 token: tok6 ANTHROPIC_API_KEY="key7"',
    '{"refreshToken":"ref8","client_secret":"sec9"}',
    'url=https://alice:p10@example.invalid/?access_token=query11',
    `host=${syntheticPrivateIp}`,
  ].join('\n');
  const secrets = [
    'auth1', 'YQ==', 'b2', 'c3', 'dark', 'd4', 'pass5', 'tok6',
    'key7', 'ref8', 'sec9', 'alice', 'p10', 'query11', syntheticPrivateIp,
  ];
  const ordinary = 'step=download status=ok key=value public-id=abc123';

  loggers.forEach((logger) => {
    const sanitized = logger.sanitize(sensitiveInput);
    secrets.forEach((secret) => {
      assert.strictEqual(sanitized.indexOf(secret), -1, `sensitive value leaked: ${secret}`);
    });
    assert(sanitized.indexOf('***') !== -1);
    assert(sanitized.indexOf('[private-ip]') !== -1);
    assert.strictEqual(logger.sanitize(ordinary), ordinary);

    const messages = [];
    logger.attach({
      isDestroyed: () => false,
      webContents: { send: (channel, payload) => messages.push({ channel, payload }) },
    });
    logger.progress('test', 50, 'token=front-end-secret');
    logger.setStep('test', 'error', { message: 'Authorization: Bearer ui-secret' });
    logger.attach(null);
    assert.strictEqual(messages.length, 2);
    assert.strictEqual(JSON.stringify(messages).indexOf('front-end-secret'), -1);
    assert.strictEqual(JSON.stringify(messages).indexOf('ui-secret'), -1);
  });
});

test('deploy bootstrap contracts', async () => {
  const deployDir = path.join(__dirname, '..', 'deploy');
  const switchScript = fs.readFileSync(path.join(deployDir, 'ccswitch.sh'), 'utf8');
  const switchPowerShell = fs.readFileSync(path.join(deployDir, 'ccswitch.ps1'), 'utf8');
  const claudeScript = fs.readFileSync(path.join(deployDir, 'cc-custom.sh'), 'utf8');
  [switchScript, claudeScript].forEach((script) => {
    assert(/if command -v curl/.test(script));
    assert(/elif command -v wget/.test(script));
    assert(/PATH='\/usr\/local\/sbin:/.test(script));
    assert(!/http:\/\//i.test(script));
  });
  assert(/PINNED_VERSION="v3\.18\.0"/.test(switchScript));
  assert(!/GITHUB_API|releases\/latest/.test(switchScript));
  assert(/url_effective/.test(switchScript));
  assert(/wget never follows redirects/.test(switchScript));
  assert(/get_redirect_location/.test(switchScript));
  const switchCurl = switchScript.slice(
    switchScript.indexOf('download_with_curl()'),
    switchScript.indexOf('get_http_status()'),
  );
  const switchWget = switchScript.slice(
    switchScript.indexOf('download_with_wget()'),
    switchScript.indexOf('download_file()'),
  );
  assert(/--max-filesize/.test(switchCurl));
  assert(!/--max-filesize/.test(switchWget));
  assert(/ulimit -c 0/.test(switchWget));
  assert(/ulimit -f/.test(switchWget));
  assert(/within_size_limit/.test(switchWget));
  assert(/!seen\[line\]\+\+/.test(switchScript));
  assert(/\[ -L "\$INSTALL_DIR" \]/.test(switchScript));
  assert(/mktemp "\$INSTALL_DIR\/\.cc-switch\.AppImage\.XXXXXX"/.test(switchScript));
  assert(/for managed_dir in/.test(claudeScript));
  assert(/PKEXEC_UID/.test(claudeScript));
  assert(/secure_system_directory/.test(claudeScript));
  assert(/--max-redirect=0/.test(claudeScript));
  const claudeLogicalCommands = claudeScript.replace(/\\\r?\n[ \t]*/g, ' ');
  assert(!/(?:^|\n)[ \t]*wget[^\n]*--max-filesize/m.test(claudeLogicalCommands));
  assert(/downloaded_file_within_limit/.test(claudeScript));
  assert(/ulimit -c 0/.test(claudeScript));
  assert(/ulimit -f/.test(claudeScript));
  assert(/SHA256 校验失败/.test(switchScript));
  assert(/while \[ "\$DOWNLOAD_ROUND" -le "\$MAX_ATTEMPTS" \]/.test(switchScript));
  assert(
    switchScript.lastIndexOf('https://gh-proxy.com/')
      < switchScript.lastIndexOf('https://ghproxy.net/'),
  );
  ['ghproxy.net', 'gh-proxy.com', 'ghfast.top'].forEach((host) => {
    assert(switchScript.includes(host));
    assert(switchPowerShell.includes(host));
  });
  assert(/function Assert-AssetTransportUrl/.test(switchPowerShell));
  assert(/New-TransportSources/.test(switchPowerShell));
  assert(
    switchPowerShell.indexOf("'https://gh-proxy.com/'")
      < switchPowerShell.indexOf("'https://ghproxy.net/'"),
  );
  assert.strictEqual(
    (switchPowerShell.match(/\[void\]\(Assert-PrivateInstallerFilePath/g) || []).length,
    3,
  );
  assert(/\[void\]\(Invoke-HttpDownloadOnce/.test(switchPowerShell));
  assert(/try\s*\{\s*\$msiFingerprint = Invoke-VerifiedDownload/.test(switchPowerShell));
  assert(/catch\s*\{\s*\$msiFingerprint = \$null/.test(switchPowerShell));
  assert(/\$sourceIndex \+ 1 -lt \$transportSources\.Count/.test(switchPowerShell));
  assert(/当前下载源不可用，将尝试下一个来源/.test(switchPowerShell));
});

test('build metadata contracts', async () => {
  const root = path.join(__dirname, '..');
  const buildScript = fs.readFileSync(path.join(root, 'scripts', 'build.js'), 'utf8');
  const linuxBuildConfig = fs.readFileSync(
    path.join(root, 'linux-installer', 'electron-builder.yml'),
    'utf8',
  );
  const rootPackage = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const linuxPackage = JSON.parse(
    fs.readFileSync(path.join(root, 'linux-installer', 'package.json'), 'utf8'),
  );
  assert.deepStrictEqual(rootPackage.engines, { node: '11.9.x', npm: '6.x' });
  assert.strictEqual(linuxPackage.version, rootPackage.version);
  assert.deepStrictEqual(linuxPackage.engines, rootPackage.engines);
  assert.deepStrictEqual(linuxPackage.devDependencies, rootPackage.devDependencies);
  assert(/npmRebuild:\s*false/.test(linuxBuildConfig));
  assert(/extraResources:/.test(linuxBuildConfig));
  assert(/from:\s*\.\.\/deploy\/cc-custom\.sh/.test(linuxBuildConfig));
  assert(/from:\s*\.\.\/deploy\/ccswitch\.sh/.test(linuxBuildConfig));
  assert(/to:\s*deploy\/ccswitch\.sh/.test(linuxBuildConfig));
  assert(/process\.resourcesPath/.test(fs.readFileSync(
    path.join(root, 'linux-installer', 'src', 'main', 'installer', 'bundledScript.js'),
    'utf8',
  )));
  assert(/target === 'AppImage' && !architecture/.test(buildScript));
  assert(/\? \['x64', 'arm64'\]/.test(buildScript));
  assert(/for \(const buildArchitecture of buildArchitectures\)/.test(buildScript));
  assert(/const args = \[builderCli, `--\$\{platform\}`\];/.test(buildScript));
  assert(/if \(target\) args\.push\(target\)/.test(buildScript));
  assert(/if \(buildArchitecture\) args\.push\(`--\$\{buildArchitecture\}`\)/.test(buildScript));
  assert(/shell:\s*false/.test(buildScript));
  assert(!/shell:\s*true/.test(buildScript));
});

test('AppImage archive preserves executable mode and payload', async () => {
  const tempRoot = process.env.CCP_TEST_TMPDIR || os.tmpdir();
  const temp = fs.mkdtempSync(path.join(tempRoot, 'appimage-archive-test-'));
  const input = path.join(temp, 'Test-x86_64.AppImage');
  const output = `${input}.tar.gz`;
  const payload = Buffer.alloc(4096, 0x5a);
  payload.set(Buffer.from([0x7f, 0x45, 0x4c, 0x46]), 0);
  payload.set(Buffer.from([0x41, 0x49, 0x02]), 8);

  try {
    fs.writeFileSync(input, payload, { mode: 0o600 });
    const archive = require(path.join(__dirname, '..', 'scripts', 'appimageArchive'));
    await archive.createExecutableAppImageArchive(input, output);
    const tar = zlib.gunzipSync(fs.readFileSync(output));
    const name = tar.slice(0, 100).toString('ascii').replace(/\0.*$/, '');
    const mode = parseInt(tar.slice(100, 108).toString('ascii').replace(/\0.*$/, ''), 8);
    const size = parseInt(tar.slice(124, 136).toString('ascii').replace(/\0.*$/, ''), 8);

    assert.strictEqual(name, path.basename(input));
    assert.strictEqual(mode, 0o755);
    assert.strictEqual(size, payload.length);
    assert.deepStrictEqual(tar.slice(512, 512 + size), payload);
  } finally {
    removeTree(temp);
  }
});

test('privileged process does not expose an interactive shell', () => {
  const root = path.join(__dirname, '..');
  const files = [
    path.join(root, 'src', 'main', 'ipc.js'),
    path.join(root, 'linux-installer', 'src', 'main', 'ipc.js'),
  ];
  files.forEach((file) => {
    const source = fs.readFileSync(file, 'utf8');
    assert(!/openTerminal|cmd\.exe|exec bash|gnome-terminal|x-terminal-emulator|\bxterm\b/.test(source));
    assert(/installer:verifyClaude/.test(source));
    assert(/execFile\(executable, \['--version'\]/.test(source));
    assert(/maxBuffer:\s*4096/.test(source));
  });
});

test('GUI installers execute only bundled hash-pinned scripts', () => {
  const root = path.join(__dirname, '..');
  const linuxEnv = require(path.join(root, 'linux-installer', 'src', 'main', 'env'));
  const linuxBundledRunner = path.join(
    root,
    'linux-installer',
    'src',
    'main',
    'installer',
    'bundledScript.js',
  );
  const cases = [
    {
      env: require(path.join(root, 'src', 'main', 'env')),
      metadata: 'INSTALL_SCRIPT',
      runner: path.join(root, 'src', 'main', 'installer', 'claudeRunner.js'),
      script: path.join(root, 'deploy', 'cc-custom.ps1'),
      relativePath: 'deploy/cc-custom.ps1',
    },
    {
      env: linuxEnv,
      metadata: 'INSTALL_SCRIPT',
      runner: linuxBundledRunner,
      script: path.join(root, 'deploy', 'cc-custom.sh'),
      relativePath: 'deploy/cc-custom.sh',
    },
    {
      env: linuxEnv,
      metadata: 'CCSWITCH_SCRIPT',
      runner: linuxBundledRunner,
      script: path.join(root, 'deploy', 'ccswitch.sh'),
      relativePath: 'deploy/ccswitch.sh',
    },
  ];
  cases.forEach((entry) => {
    const metadata = entry.env[entry.metadata];
    const expected = crypto.createHash('sha256').update(fs.readFileSync(entry.script)).digest('hex');
    assert.strictEqual(metadata.relativePath, entry.relativePath);
    assert.strictEqual(metadata.sha256, expected);
    const runner = fs.readFileSync(entry.runner, 'utf8');
    assert(/readVerifiedScript/.test(runner));
    assert(/proc\.stdin\.end\(content\)/.test(runner));
    assert(!/\bdownload\(/.test(runner));
  });

  const privilegedSources = [
    path.join(root, 'src', 'main', 'ipc.js'),
    path.join(root, 'linux-installer', 'src', 'main', 'ipc.js'),
    path.join(root, 'src', 'renderer', 'app.js'),
    path.join(root, 'linux-installer', 'src', 'renderer', 'app.js'),
  ].map((file) => fs.readFileSync(file, 'utf8')).join('\n');
  assert(!/sources:(?:list|speedTest)|autoBest|sourceId/.test(privilegedSources));
});

(async () => {
  for (const entry of tests) {
    try {
      await entry.handler();
      console.log(`[test] PASS ${entry.name}`);
    } catch (error) {
      console.error(`[test] FAIL ${entry.name}: ${error.stack || error}`);
      process.exitCode = 1;
      break;
    }
  }
  if (!process.exitCode) console.log(`[test] ${tests.length} 组测试全部通过`);
})();
