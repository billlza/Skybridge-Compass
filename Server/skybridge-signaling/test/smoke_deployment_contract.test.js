'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const serverRoot = path.resolve(__dirname, '..');
const smokeScript = path.join(serverRoot, 'deploy/scripts/smoke_local.sh');
const fingerprint = 'skybridge-signaling/deployment-contract-test';

function responseFor(method, pathname, build) {
  const common = { serverBuildFingerprint: build };
  switch (pathname) {
    case '/':
      return { status: 200, body: { ...common, ok: true, service: 'skybridge-signaling',
        endpoints: ['/api/turn/credentials', '/api/presence/register', '/api/devices/list'] } };
    case '/health':
      return { status: 200, body: { ...common, ready: true, sms: { ready: true } } };
    case '/readyz':
      return { status: 200, body: { ...common, status: 'ready' } };
    case '/api/presence/register':
      if (method === 'POST') return { status: 401, body: { error: 'missing_bearer_token' } };
      break;
    case '/api/devices/list':
      if (method === 'GET') return { status: 401, body: { error: 'missing_bearer_token' } };
      break;
    case '/api/turn/credentials':
      return { status: 401, body: { error: 'missing_turn_admission_token' } };
    default:
      break;
  }
  return { status: 404, body: 'Cannot ' + method + ' ' + pathname };
}

async function serve(t, responder, host = '127.0.0.1') {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    try {
      const pathname = new URL(req.url, 'http://localhost').pathname;
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const request = { method: req.method, pathname, headers: req.headers, body: Buffer.concat(chunks).toString('utf8') };
      requests.push(request);
      const reply = await responder(request);
      if (reply.disconnect) {
        req.socket.destroy();
        return;
      }
      res.writeHead(reply.status, { 'Content-Type': 'application/json', ...reply.headers });
      res.end(typeof reply.body === 'string' ? reply.body : JSON.stringify(reply.body));
    } catch (error) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: error.message }));
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, resolve);
  });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  const authority = host.includes(':') ? '[' + host + ']' : host;
  return { baseURL: 'http://' + authority + ':' + server.address().port, requests };
}

function runScript(script, args, env = {}, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [script, ...args], {
      env: { ...process.env, ...env },
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      try { process.kill(-child.pid, 'SIGTERM'); } catch (error) {
        if (error.code !== 'ESRCH') reject(error);
      }
    }, timeoutMs);
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', (error) => { clearTimeout(timer); reject(error); });
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

test('deployment smoke verifies build, advertised routes, HTTP methods and credential-free auth refusals', async (t) => {
  const fixture = await serve(t, ({ method, pathname }) => responseFor(method, pathname, fingerprint));
  const result = await runScript(smokeScript, [fixture.baseURL + '/', '', fingerprint], {
    SKYBRIDGE_CLIENT_API_KEY: 'must-not-be-sent'
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /Deployment contract checks passed/);
  assert.deepEqual(fixture.requests.map(({ method, pathname }) => [method, pathname]), [
    ['GET', '/'], ['GET', '/health'], ['GET', '/readyz'],
    ['POST', '/api/presence/register'], ['GET', '/api/devices/list'], ['GET', '/api/turn/credentials']
  ]);
  assert.equal(fixture.requests[3].body, '{}');
  for (const request of fixture.requests) {
    assert.equal(request.headers.authorization, undefined);
    assert.equal(request.headers['x-api-key'], undefined);
  }
});

const rejectedResponses = [
  ['older root build', '/', (reply) => ({ ...reply, body: { ...reply.body, serverBuildFingerprint: 'old-build' } }), /fingerprint/],
  ['older readyz build with HTTP 200', '/readyz', (reply) => ({ ...reply, body: { ...reply.body, serverBuildFingerprint: 'old-build' } }), /fingerprint/],
  ['missing build identity', '/', (reply) => ({ ...reply, body: { ...reply.body, serverBuildFingerprint: undefined } }), /fingerprint/],
  ['missing route advertisement', '/', (reply) => ({ ...reply, body: { ...reply.body, endpoints: ['/api/turn/credentials'] } }), /advertised endpoint/],
  ['not-ready body with HTTP 200', '/readyz', (reply) => ({ ...reply, body: { ...reply.body, status: 'not_ready' } }), /did not report ready/],
  ['invalid JSON', '/', () => ({ status: 200, body: '<html>upstream failure</html>' }), /valid JSON/],
  ['missing presence handler', '/api/presence/register', () => ({ status: 404, body: 'Cannot POST /api/presence/register' }), /status=404/],
  ['missing device-list handler', '/api/devices/list', () => ({ status: 404, body: { error: 'not_found' } }), /status=404/],
  ['unrelated 401 response', '/api/devices/list', () => ({ status: 401, body: { error: 'unauthorized', password: 'private-turn-value' } }), /missing_bearer_token/],
  ['global authentication middleware', '/', () => ({ status: 401, body: { error: 'missing_bearer_token' } }), /expected HTTP 200/],
  ['redirect', '/api/devices/list', () => ({ status: 302, headers: { Location: '/redirect-target' }, body: { error: 'redirect' } }), /status=302/],
  ['connection loss', '/api/devices/list', () => ({ disconnect: true }), /transport failure/]
];
for (const [name, target, modify, expectedError] of rejectedResponses) {
  test('deployment smoke rejects ' + name, async (t) => {
    const fixture = await serve(t, ({ method, pathname }) => {
      const reply = responseFor(method, pathname, fingerprint);
      return pathname === target ? modify(reply) : reply;
    });
    const result = await runScript(smokeScript, [fixture.baseURL, '', fingerprint]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, expectedError);
    assert.doesNotMatch(result.stdout + result.stderr, /private-turn-value|upstream failure/);
    assert.doesNotMatch(result.stdout, /Deployment contract checks passed/);
    assert.ok(!fixture.requests.some((request) => request.pathname === '/redirect-target'));
  });
}

test('deployment smoke rejects missing expected identity and credential-bearing URLs before I/O', async (t) => {
  const fixture = await serve(t, ({ method, pathname }) => responseFor(method, pathname, fingerprint));
  const missing = await runScript(smokeScript, [fixture.baseURL, ''], { SKYBRIDGE_EXPECTED_SERVER_BUILD_FINGERPRINT: '' });
  assert.notEqual(missing.code, 0);
  assert.match(missing.stderr, /explicit expected/);
  const invalid = await runScript(smokeScript, [fixture.baseURL.replace('http://', 'http://user:private-password@'), '', fingerprint]);
  assert.notEqual(invalid.code, 0);
  assert.doesNotMatch(invalid.stdout + invalid.stderr, /private-password/);
  const emptyBase = await runScript(smokeScript, ['', '', fingerprint]);
  assert.notEqual(emptyBase.code, 0);
  assert.match(emptyBase.stderr, /invalid base URL/);
  assert.equal(fixture.requests.length, 0);
});

async function writeNodeCommand(directory, name, main) {
  const filename = path.join(directory, name);
  await fs.writeFile(filename, '#!' + process.execPath + '\n(' + main.toString() + ')();\n', { mode: 0o755 });
}

async function deploymentFixture(t, mode, { ipv6 = false, quotedAppPath = false, existingDropin = false, symlinkDropin = false, failRuntimeInstall = false, writableParent = false, legacyWithoutFingerprint = false } = {}) {
  const directory = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'skybridge-deployment-contract-')));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const project = path.join(directory, 'project');
  const serviceRoot = path.join(project, 'Server/skybridge-signaling');
  const scripts = path.join(serviceRoot, 'deploy/scripts');
  const commandDirectory = path.join(directory, 'bin');
  const runtimeDir = path.join(directory, 'selected-node-runtime');
  const systemdDir = path.join(directory, 'systemd');
  const serviceName = 'skybridge-contract-' + path.basename(directory);
  const appDir = path.join(directory, quotedAppPath ? "app's prepared releases" : 'app');
  const oldRelease = path.join(appDir, 'releases/previous');
  const commandLog = path.join(directory, 'commands.jsonl');
  const runtimeLog = path.join(directory, 'runtime.jsonl');
  const unitPath = path.join(systemdDir, serviceName + '.service');
  const dropinPath = path.join(systemdDir, serviceName + '.service.d/20-node-runtime.conf');
  const originalUnit = '[Service]\nExecStart=/usr/bin/env node server.js\n# preserved original unit\n';
  const originalDropin = '[Service]\nEnvironment=PREEXISTING_RUNTIME=preserve\n';
  const externalDropinPath = path.join(directory, 'original-runtime.conf');
  await Promise.all([
    fs.mkdir(scripts, { recursive: true }), fs.mkdir(commandDirectory),
    fs.mkdir(path.join(serviceRoot, 'deploy/systemd'), { recursive: true }),
    fs.mkdir(oldRelease, { recursive: true }), fs.mkdir(path.join(appDir, 'shared/config'), { recursive: true }),
    fs.mkdir(path.dirname(dropinPath), { recursive: true }), fs.mkdir(path.join(runtimeDir, 'bin'), { recursive: true }),
    fs.mkdir(path.join(runtimeDir, 'lib/node_modules/npm/bin'), { recursive: true })
  ]);
  await fs.symlink(process.execPath, path.join(runtimeDir, 'bin/node'));
  await fs.writeFile(path.join(runtimeDir, 'lib/node_modules/npm/bin/npm-cli.js'),
    "if (process.argv[2] !== 'ci') process.exit(1); require('node:fs').appendFileSync(process.env.CONTRACT_RUNTIME_LOG, JSON.stringify({role:'npm',execPath:process.execPath})+'\\n');\n");
  await fs.writeFile(unitPath, originalUnit, { mode: 0o640 });
  if (existingDropin) {
    if (symlinkDropin) {
      await fs.writeFile(externalDropinPath, originalDropin, { mode: 0o600 });
      await fs.symlink(path.relative(path.dirname(dropinPath), externalDropinPath), dropinPath);
    } else {
      await fs.writeFile(dropinPath, originalDropin, { mode: 0o600 });
    }
  }
  const originalUnitOwner = await fs.stat(unitPath);
  const originalDropinOwner = existingDropin ? await fs.stat(dropinPath) : null;
  if (!legacyWithoutFingerprint) await fs.writeFile(path.join(oldRelease, '.skybridge-build-fingerprint'), 'skybridge-signaling/previous\n');
  await fs.symlink(oldRelease, path.join(appDir, 'current'));
  await fs.copyFile(smokeScript, path.join(scripts, 'smoke_local.sh'));
  await fs.copyFile(path.join(serverRoot, 'deploy/scripts/deploy_remote.sh'), path.join(scripts, 'deploy_remote.sh'));
  await fs.copyFile(path.join(serverRoot, 'deploy/scripts/rollback_remote.sh'), path.join(scripts, 'rollback_remote.sh'));
  await fs.copyFile(path.join(serverRoot, 'deploy/scripts/release_runtime_journal.sh'), path.join(scripts, 'release_runtime_journal.sh'));
  await fs.copyFile(path.join(serverRoot, 'deploy/systemd/skybridge-signaling.service'), path.join(serviceRoot, 'deploy/systemd/skybridge-signaling.service'));
  await fs.writeFile(path.join(appDir, 'shared/config/production.env'), 'CONTRACT_CANDIDATE_MODE=' + mode + '\n');
  const serverSource = [
    "'use strict';",
    "const http = require('node:http'); const fs = require('node:fs'); const path = require('node:path');",
    responseFor.toString(),
    "const build = fs.readFileSync(path.join(__dirname, '.skybridge-build-fingerprint'), 'utf8').trim();",
    "fs.appendFileSync(process.env.CONTRACT_RUNTIME_LOG, JSON.stringify({role:'candidate',execPath:process.execPath})+'\\n');",
    "http.createServer((req, res) => {",
    "  let pathname = new URL(req.url, 'http://localhost').pathname;",
    "  if (pathname === '/custom/readyz') pathname = '/readyz';",
    "  const reply = process.env.CONTRACT_CANDIDATE_MODE === 'candidate_missing_route' && pathname === '/api/devices/list'",
    "    ? {status:404, body:{error:'not_found'}} : responseFor(req.method, pathname, build);",
    "  res.writeHead(reply.status, {'Content-Type':'application/json'});",
    "  res.end(typeof reply.body === 'string' ? reply.body : JSON.stringify(reply.body));",
    "}).listen(Number(process.env.PORT), process.env.HOST, () => console.log('candidate fixture listening'));"
  ].join('\n');
  await fs.writeFile(path.join(serviceRoot, 'server.js'), serverSource);
  let restoredHealthOverride = null;
  const live = await serve(t, async ({ method, pathname }) => {
    const currentRelease = await fs.readlink(path.join(appDir, 'current'));
    const currentBuild = currentRelease === oldRelease ? 'skybridge-signaling/previous'
      : (await fs.readFile(path.join(currentRelease, '.skybridge-build-fingerprint'), 'utf8')).trim();
    const build = mode === 'promoted_wrong_build' && currentRelease !== oldRelease ? 'skybridge-signaling/other-process' : currentBuild;
    const reply = responseFor(method, pathname === '/custom/readyz' ? '/readyz' : pathname, build);
    if (currentRelease === oldRelease && ['/health', '/custom/readyz'].includes(pathname)) {
      if (restoredHealthOverride === 'wrong') reply.body.serverBuildFingerprint = 'skybridge-signaling/wrong-restored-process';
      if (restoredHealthOverride === 'missing') delete reply.body.serverBuildFingerprint;
    }
    return reply;
  }, ipv6 ? '::1' : '127.0.0.1');
  await writeNodeCommand(commandDirectory, 'git', function () {
    process.stdout.write(require('node:path').basename(process.env.CONTRACT_DIRECTORY) + '\n');
  });
  await writeNodeCommand(commandDirectory, 'npm', function () {
    process.stderr.write('Ambient npm must not be used\n');
    process.exit(1);
  });
  await writeNodeCommand(commandDirectory, 'node', function () {
    if (process.env.CONTRACT_REMOTE_NODE === '1') {
      process.stderr.write('Ambient remote Node must not be used\n');
      process.exit(1);
    }
    const result = require('node:child_process').spawnSync(process.env.CONTRACT_REAL_NODE, process.argv.slice(2), { stdio: 'inherit' });
    if (result.error) throw result.error;
    process.exit(result.status === null ? 1 : result.status);
  });
  await writeNodeCommand(commandDirectory, 'id', function () {
    if (process.argv[2] === '-u' && process.argv[3] === 'skybridge') process.stdout.write('1001\n');
    else process.exit(1);
  });
  await writeNodeCommand(commandDirectory, 'scp', function () {
    const fs = require('node:fs');
    const args = process.argv.slice(2);
    for (const option of ['BatchMode=yes', 'StrictHostKeyChecking=yes', 'ConnectTimeout=10', 'ServerAliveInterval=15', 'ServerAliveCountMax=3']) {
      if (!args.includes(option)) throw new Error('Missing bounded SSH option: ' + option);
    }
    const source = args[args.length - 2];
    const target = args[args.length - 1];
    if (!target.startsWith('fixtureuser@fixture.invalid:')) process.exit(1);
    fs.copyFileSync(source, target.slice('fixtureuser@fixture.invalid:'.length));
  });
  await writeNodeCommand(commandDirectory, 'ssh', function () {
    const { spawnSync } = require('node:child_process');
    const args = process.argv.slice(2);
    for (const option of ['BatchMode=yes', 'StrictHostKeyChecking=yes', 'ConnectTimeout=10', 'ServerAliveInterval=15', 'ServerAliveCountMax=3']) {
      if (!args.includes(option)) throw new Error('Missing bounded SSH option: ' + option);
    }
    if (args[args.length - 2] !== 'fixtureuser@fixture.invalid') process.exit(1);
    const result = spawnSync('bash', ['-c', args[args.length - 1]], {
      stdio: 'inherit', env: { ...process.env, CONTRACT_REMOTE_NODE: '1' }
    });
    if (result.error) throw result.error;
    process.exit(result.status === null ? 1 : result.status);
  });
  await writeNodeCommand(commandDirectory, 'sudo', function () {
    const fs = require('node:fs');
    const path = require('node:path');
    const { spawnSync } = require('node:child_process');
    const args = process.argv.slice(2).map((value) => value.startsWith('/etc/systemd/system')
      ? path.join(process.env.CONTRACT_SYSTEMD_DIR, value.slice('/etc/systemd/system'.length)) : value);
    if (args[0] === '-u') args.splice(0, 2);
    const command = args.shift();
    if (command === 'chown') {
      fs.appendFileSync(process.env.CONTRACT_COMMAND_LOG, JSON.stringify(['chown', ...args]) + '\n');
      process.exit(0);
    }
    if (command === 'bash' && args[0] === '-c' && args[1].includes('printf read_only')) {
      process.stdout.write(process.env.CONTRACT_WRITABLE_PARENT === '1' ? 'writable' : 'read_only');
      process.exit(0);
    }
    if (command === 'install' && process.env.CONTRACT_FAIL_RUNTIME_INSTALL === '1' && args.at(-1).endsWith('/20-node-runtime.conf')) {
      process.stderr.write('Fixture runtime drop-in installation failed\n');
      process.exit(1);
    }
    const result = spawnSync(command, args, { stdio: 'inherit' });
    if (result.error) throw result.error;
    process.exit(result.status === null ? 1 : result.status);
  });
  await writeNodeCommand(commandDirectory, 'systemctl', function () {
    const fs = require('node:fs');
    const path = require('node:path');
    const args = process.argv.slice(2);
    fs.appendFileSync(process.env.CONTRACT_COMMAND_LOG, JSON.stringify(args) + '\n');
    if (args[0] === 'restart') {
      const dropin = path.join(process.env.CONTRACT_SYSTEMD_DIR, args[1] + '.service.d/20-node-runtime.conf');
      const body = fs.existsSync(dropin) ? fs.readFileSync(dropin, 'utf8') : '';
      const selected = body.split('\n').find((line) => line.startsWith('ExecStart=/'));
      fs.appendFileSync(process.env.CONTRACT_RUNTIME_LOG, JSON.stringify({ role: 'systemd', execStart: selected || 'default' }) + '\n');
    }
    process.stdout.write('fixture service running\n');
  });
  const env = {
    PATH: commandDirectory + path.delimiter + process.env.PATH,
    CONTRACT_DIRECTORY: directory,
    CONTRACT_COMMAND_LOG: commandLog,
    CONTRACT_RUNTIME_LOG: runtimeLog,
    CONTRACT_REAL_NODE: process.execPath,
    CONTRACT_SYSTEMD_DIR: systemdDir,
    CONTRACT_FAIL_RUNTIME_INSTALL: failRuntimeInstall ? '1' : '0',
    CONTRACT_WRITABLE_PARENT: writableParent ? '1' : '0'
  };
  const args = ['--host', 'fixture.invalid', '--user', 'fixtureuser', '--app-dir', appDir,
    '--service', serviceName, '--health-url', live.baseURL + '/custom/readyz'];
  return {
    appDir, oldRelease, directory, runtimeDir, unitPath, dropinPath,
    async deploy(extra = []) {
      return runScript(path.join(scripts, 'deploy_remote.sh'), [...args, '--node-runtime-dir', runtimeDir, ...extra], env, 45_000);
    },
    async rollback(extra = []) {
      return runScript(path.join(scripts, 'rollback_remote.sh'), [...args, ...extra], env, 30_000);
    },
    overrideRestoredHealth(override) {
      assert.ok(['wrong', 'missing'].includes(override));
      restoredHealthOverride = override;
    },
    async assertOriginalConfiguration() {
      assert.equal(await fs.readFile(unitPath, 'utf8'), originalUnit);
      const unitStat = await fs.stat(unitPath);
      assert.equal(unitStat.mode & 0o777, 0o640);
      assert.equal(unitStat.uid, originalUnitOwner.uid);
      assert.equal(unitStat.gid, originalUnitOwner.gid);
      if (existingDropin) {
        assert.equal(await fs.readFile(dropinPath, 'utf8'), originalDropin);
        const dropinStat = await fs.stat(dropinPath);
        assert.equal(dropinStat.mode & 0o777, 0o600);
        assert.equal(dropinStat.uid, originalDropinOwner.uid);
        assert.equal(dropinStat.gid, originalDropinOwner.gid);
        if (symlinkDropin) {
          assert.equal(await fs.readlink(dropinPath), path.relative(path.dirname(dropinPath), externalDropinPath));
          assert.equal(await fs.readFile(externalDropinPath, 'utf8'), originalDropin);
        }
      } else {
        await assert.rejects(fs.stat(dropinPath), { code: 'ENOENT' });
      }
    },
    async runtimeCalls() {
      return (await fs.readFile(runtimeLog, 'utf8')).trim().split('\n').map(JSON.parse);
    },
    async replaceRuntimeMetadata(overrides) {
      const metadata = { version: process.versions.node, platform: process.platform, arch: process.arch, execPath: process.execPath, ...overrides };
      const runtimeNode = path.join(runtimeDir, 'bin/node');
      await fs.unlink(runtimeNode);
      await fs.writeFile(runtimeNode, '#!' + process.execPath + '\n' +
        'if(process.argv[2] === "-p") process.stdout.write(' + JSON.stringify(JSON.stringify(metadata)) + ');\n' +
        'else { const result = require("node:child_process").spawnSync(' + JSON.stringify(process.execPath) +
        ', process.argv.slice(2), {stdio:"inherit"}); if(result.error) throw result.error; process.exit(result.status === null ? 1 : result.status); }\n', { mode: 0o755 });
    },
    async commands() {
      try { return (await fs.readFile(commandLog, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse).filter((command) => command[0] !== 'chown'); }
      catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    },
    async ownershipChanges() {
      return (await fs.readFile(commandLog, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse).filter((command) => command[0] === 'chown');
    }
  };
}

test('deployment refuses a healthy candidate with a missing required route before promotion', async (t) => {
  const fixture = await deploymentFixture(t, 'candidate_missing_route');
  const result = await fixture.deploy();
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /GET \/api\/devices\/list status=404/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  assert.deepEqual(await fixture.commands(), []);
  const releases = await fs.readdir(path.join(fixture.appDir, 'releases'));
  const candidate = releases.find((release) => release !== 'previous');
  assert.ok(candidate);
  assert.match(await fs.readFile(path.join(fixture.appDir, 'releases', candidate, '.candidate-boot.log'), 'utf8'), /candidate fixture listening/);
});

test('deployment restores the previous current release when the promoted process reports another build', async (t) => {
  const fixture = await deploymentFixture(t, 'promoted_wrong_build', { existingDropin: true, symlinkDropin: true });
  const result = await fixture.deploy();
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /fingerprint does not match/);
  assert.match(result.stderr, /Rolling back current symlink/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  assert.equal((await fixture.commands()).filter((args) => args[0] === 'restart').length, 2);
  assert.doesNotMatch(result.stdout, /deployed and verified successfully/);
  await fixture.assertOriginalConfiguration();
});

test('deployment prepared-only mode leaves current and the running service untouched', async (t) => {
  const fixture = await deploymentFixture(t, 'ready');
  const result = await fixture.deploy(['--skip-systemd']);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /Prepared only/);
  assert.doesNotMatch(result.stdout, /deployed and verified successfully/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  assert.deepEqual(await fixture.commands(), []);
  await fixture.assertOriginalConfiguration();
});

test('deployment derives an IPv6 origin with port and safely passes quoted application paths', async (t) => {
  const fixture = await deploymentFixture(t, 'ready', { ipv6: true, quotedAppPath: true });
  const result = await fixture.deploy();
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /deployed and verified successfully/);
  assert.notEqual(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  assert.equal((await fixture.commands()).filter((args) => args[0] === 'restart').length, 1);
  assert.match(await fs.readFile(fixture.dropinPath, 'utf8'), new RegExp('ExecStart=' + fixture.runtimeDir + '/bin/node server\\.js'));
  const calls = await fixture.runtimeCalls();
  assert.deepEqual(calls.filter((call) => call.role === 'npm' || call.role === 'candidate').map((call) => call.role).sort(), ['candidate', 'npm']);
  for (const call of calls.filter((item) => item.execPath)) {
    assert.equal(await fs.realpath(call.execPath), await fs.realpath(path.join(fixture.runtimeDir, 'bin/node')));
  }
  assert.equal(calls.find((call) => call.role === 'systemd').execStart, 'ExecStart=' + fixture.runtimeDir + '/bin/node server.js');
  for (const change of await fixture.ownershipChanges()) {
    if (!change.includes('skybridge:skybridge') || change.includes('-h')) continue;
    assert.ok(!change.includes('-R'), 'service ownership must never be applied recursively to deployment state');
    for (const target of change.slice(change.indexOf('skybridge:skybridge') + 1)) {
      assert.ok(target.endsWith('/node_modules') || target.endsWith('/.npm-cache'), target);
    }
  }
});

test('deployment rejects a query-bearing health URL before any remote command or shell expansion', async (t) => {
  const fixture = await deploymentFixture(t, 'ready');
  const marker = path.join(fixture.directory, 'unexpected-shell-command');
  const result = await fixture.deploy(['--health-url', 'http://127.0.0.1/readyz?probe=$(touch%20' + marker + ')']);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /without credentials, query, fragment or whitespace/);
  assert.deepEqual(await fixture.commands(), []);
  await assert.rejects(fs.stat(marker), { code: 'ENOENT' });
  assert.deepEqual(await fs.readdir(path.join(fixture.appDir, 'releases')), ['previous']);
});

for (const [name, overrides, message] of [
  ['old Node version', { version: '20.19.6' }, /24\.6\.0 or newer/],
  ['wrong runtime architecture', { arch: 'unmatched-architecture' }, /platform and architecture/]
]) {
  test('deployment rejects ' + name + ' before changing service configuration', async (t) => {
    const fixture = await deploymentFixture(t, 'ready', { existingDropin: true });
    await fixture.replaceRuntimeMetadata(overrides);
    const result = await fixture.deploy();
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, message);
    assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
    assert.deepEqual(await fixture.commands(), []);
    await fixture.assertOriginalConfiguration();
  });
}

test('deployment rejects an unavailable selected runtime without using ambient Node', async (t) => {
  const fixture = await deploymentFixture(t, 'ready');
  const result = await fixture.deploy(['--node-runtime-dir', path.join(fixture.directory, 'missing-runtime')]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Selected Node runtime is not executable/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  assert.deepEqual(await fixture.commands(), []);
  await fixture.assertOriginalConfiguration();
});

test('deployment refuses a service-writable release management parent before extracting a candidate', async (t) => {
  const fixture = await deploymentFixture(t, 'ready', { writableParent: true });
  const result = await fixture.deploy();
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /Deployment management directory is writable by the service account/);
  assert.deepEqual(await fs.readdir(path.join(fixture.appDir, 'releases')), ['previous']);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  await fixture.assertOriginalConfiguration();
});

test('deployment restores original service files after a partial runtime configuration install fails', async (t) => {
  const fixture = await deploymentFixture(t, 'ready', { existingDropin: true, failRuntimeInstall: true });
  const result = await fixture.deploy();
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /runtime drop-in installation failed/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  await fixture.assertOriginalConfiguration();
  assert.doesNotMatch(result.stdout, /deployed and verified successfully/);
});

test('manual rollback restores the recorded legacy predecessor and its original default Node service configuration', async (t) => {
  const fixture = await deploymentFixture(t, 'ready', { legacyWithoutFingerprint: true });
  const deployed = await fixture.deploy();
  assert.equal(deployed.code, 0, deployed.stderr);
  const candidate = await fs.readlink(path.join(fixture.appDir, 'current'));
  assert.equal((await fs.readFile(path.join(candidate, '.node-runtime-dir'), 'utf8')).trim(), fixture.runtimeDir);
  assert.equal((await fs.readFile(path.join(candidate, '.service-runtime-journal/previous-health-build'), 'utf8')).trim(), 'skybridge-signaling/previous');
  const unrelated = path.join(fixture.appDir, 'releases/newer-failed-candidate');
  await fs.mkdir(unrelated);
  const rolledBack = await fixture.rollback();
  assert.equal(rolledBack.code, 0, rolledBack.stderr);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), fixture.oldRelease);
  await fixture.assertOriginalConfiguration();
  await assert.rejects(fs.stat(path.join(fixture.oldRelease, '.node-runtime-dir')), { code: 'ENOENT' });
  await assert.rejects(fs.stat(path.join(fixture.oldRelease, '.skybridge-build-fingerprint')), { code: 'ENOENT' });
  const calls = await fixture.runtimeCalls();
  assert.equal(calls.filter((call) => call.role === 'systemd').at(-1).execStart, 'default');
});

for (const [override, error] of [
  ['wrong', /Restored service build does not match the rollback target/],
  ['missing', /no valid serverBuildFingerprint/]
]) {
  test('manual rollback refuses HTTP 200 with ' + override + ' restored build identity', async (t) => {
    const fixture = await deploymentFixture(t, 'ready', { legacyWithoutFingerprint: true });
    const deployed = await fixture.deploy();
    assert.equal(deployed.code, 0, deployed.stderr);
    fixture.overrideRestoredHealth(override);
    const result = await fixture.rollback();
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, error);
    assert.doesNotMatch(result.stdout, /Rollback completed/);
    await fixture.assertOriginalConfiguration();
  });
}

test('manual rollback rejects unknown or unverified history and a corrupted journal before changing current', async (t) => {
  const fixture = await deploymentFixture(t, 'ready');
  const deployed = await fixture.deploy();
  assert.equal(deployed.code, 0, deployed.stderr);
  const candidate = await fs.readlink(path.join(fixture.appDir, 'current'));
  const configuredUnit = await fs.readFile(fixture.unitPath, 'utf8');
  const configuredRuntime = await fs.readFile(fixture.dropinPath, 'utf8');
  const unrelated = path.join(fixture.appDir, 'releases/unverified-history');
  await fs.mkdir(unrelated);
  await fs.writeFile(path.join(unrelated, '.node-runtime-dir'), fixture.runtimeDir + '\n');
  const unknown = await fixture.rollback(['--release', 'unverified-history']);
  assert.notEqual(unknown.code, 0);
  assert.match(unknown.stderr, /no runtime record or matching previous-release journal/);
  await fs.writeFile(path.join(candidate, '.service-runtime-journal/version'), 'unsupported\n');
  const corrupted = await fixture.rollback();
  assert.notEqual(corrupted.code, 0);
  assert.match(corrupted.stderr, /Unsupported service runtime journal/);
  assert.equal(await fs.readlink(path.join(fixture.appDir, 'current')), candidate);
  assert.equal(await fs.readFile(fixture.unitPath, 'utf8'), configuredUnit);
  assert.equal(await fs.readFile(fixture.dropinPath, 'utf8'), configuredRuntime);
  assert.equal((await fixture.commands()).filter((args) => args[0] === 'restart').length, 1);
});
