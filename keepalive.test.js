'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  PROTOCOL,
  createController,
  parseListenerStatus,
  writeHealthFile,
} = require('./keepalive.js');

function createSdk(statusValues) {
  const calls = [];
  let statusHandler;
  let closeHandler;
  let statusIndex = 0;

  return {
    calls,
    emitClose(payload = '') {
      closeHandler(payload);
    },
    sdk: {
      Init(appId) {
        calls.push(['init', appId]);
      },
      RegisterRecvHonorShareGetReceiveListenerStatusRspMsg(handler) {
        statusHandler = handler;
      },
      RegisterRecvHonorShareCloseDiscoverMsg(handler) {
        closeHandler = handler;
      },
      SendCommonMsgWithReply(...args) {
        calls.push(['start', ...args]);
      },
      SendIPCMsgWithFromModuleId(toModuleId, messageId, fromModuleId, payload) {
        calls.push(['ipc', toModuleId, messageId, fromModuleId, payload]);

        if (messageId === PROTOCOL.GET_ALLOW_DISCOVER) {
          const value = statusValues[Math.min(statusIndex, statusValues.length - 1)];
          statusIndex += 1;
          queueMicrotask(() => {
            statusHandler(JSON.stringify({ listenerstatus: value }));
          });
        }
      },
    },
  };
}

const noopLogger = {
  info() {},
  warn() {},
  error() {},
};

test('parseListenerStatus accepts only the documented 0/1 response', () => {
  assert.equal(parseListenerStatus('{"listenerstatus":1}'), 1);
  assert.equal(parseListenerStatus('{"listenerstatus":0}'), 0);
  assert.equal(parseListenerStatus('{"listenerstatus":2}'), null);
  assert.equal(parseListenerStatus('not json'), null);
  assert.equal(parseListenerStatus(''), null);
});

test('enforce starts publishing, resets the timeout, and verifies discovery stays on', async () => {
  const { sdk, calls } = createSdk([1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  const status = await controller.enforce('startup', { ensurePublishing: true });

  assert.equal(status, 1);
  assert.deepEqual(calls, [
    ['init', 'notepadUpdate'],
    [
      'start',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.START_PUBLISH,
      PROTOCOL.START_PUBLISH_SUCCESS,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '1',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('enforce retries publish when discovery is still off', async () => {
  const { sdk, calls } = createSdk([0, 1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  const status = await controller.enforce('retry', { ensurePublishing: true });

  assert.equal(status, 1);
  assert.deepEqual(
    calls.map((call) => call.slice(0, call[0] === 'start' ? 3 : 4)),
    [
      ['init', 'notepadUpdate'],
      ['start', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.START_PUBLISH],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.ALLOW_DISCOVER, PROTOCOL.OFFICE_MODULE_ID],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.RESTART_STOP_PUBLISH_TIMER, PROTOCOL.OFFICE_MODULE_ID],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.GET_ALLOW_DISCOVER, PROTOCOL.OFFICE_MODULE_ID],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.ALLOW_DISCOVER, PROTOCOL.OFFICE_MODULE_ID],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.RESTART_STOP_PUBLISH_TIMER, PROTOCOL.OFFICE_MODULE_ID],
      ['ipc', PROTOCOL.SERVICE_MODULE_ID, PROTOCOL.GET_ALLOW_DISCOVER, PROTOCOL.OFFICE_MODULE_ID],
    ],
  );
});

test('steady-state checks use only timer reset plus status query', async () => {
  const { sdk, calls } = createSdk([1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  const status = await controller.enforce('steady-state');

  assert.equal(status, 1);
  assert.deepEqual(calls, [
    ['init', 'notepadUpdate'],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('recoverNow reopens discovery without relaunching the HONOR share UI', async () => {
  const { sdk, calls } = createSdk([1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  calls.length = 0;

  const recovery = await controller.recoverNow('close-event');

  assert.equal(recovery.status, 1);
  assert.ok(recovery.latencyMs >= 0);
  assert.ok(recovery.latencyMs < 1_000);
  assert.deepEqual(calls, [
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '1',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('recoverNow verifies the switch before reopening after a close notification', async () => {
  const { sdk, calls } = createSdk([1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  calls.length = 0;

  const recovery = await controller.recoverNow('close-event', {
    verifyFirst: true,
  });

  assert.equal(recovery.status, 1);
  assert.deepEqual(calls, [
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('recoverNow reopens when verification confirms the switch is off', async () => {
  const { sdk, calls } = createSdk([0, 1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  calls.length = 0;

  const recovery = await controller.recoverNow('confirmed-off', {
    verifyFirst: true,
  });

  assert.equal(recovery.status, 1);
  assert.deepEqual(calls, [
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '1',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('recoverNow falls back to starting the service when discovery cannot be enabled alone', async () => {
  const { sdk, calls } = createSdk([0, 0, 1]);
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
  });

  await controller.initialize();
  calls.length = 0;

  const recovery = await controller.recoverNow('confirmed-off', {
    verifyFirst: true,
  });

  assert.equal(recovery.status, 1);
  assert.deepEqual(calls, [
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '1',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'start',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.START_PUBLISH,
      PROTOCOL.START_PUBLISH_SUCCESS,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '1',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
    [
      'ipc',
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.GET_ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    ],
  ]);
});

test('close event requests dismissal of only the dedicated HONOR toast', async () => {
  const { sdk, emitClose } = createSdk([1]);
  let dismissCount = 0;
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
    dismissHonorToast() {
      dismissCount += 1;
    },
  });

  controller.initialize();
  emitClose('');

  assert.equal(dismissCount, 1);
});

test('intentional stop does not dismiss the HONOR toast', async () => {
  const { sdk, emitClose } = createSdk([1]);
  let dismissCount = 0;
  const controller = createController({
    sdk,
    logger: noopLogger,
    delay: async () => {},
    schedule: () => {},
    dismissHonorToast() {
      dismissCount += 1;
    },
  });

  controller.initialize();
  controller.setAutoRecoveryEnabled(false);
  emitClose('');

  assert.equal(dismissCount, 0);
});

test('writeHealthFile records a machine-readable self-check snapshot', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'honor-share-health-'));
  const healthPath = path.join(directory, 'health.json');
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  writeHealthFile(healthPath, {
    pid: 4321,
    reason: 'test',
    listenerStatus: 1,
    now: new Date('2026-11-25T12:00:00.000Z'),
  });

  assert.deepEqual(JSON.parse(fs.readFileSync(healthPath, 'utf8')), {
    schemaVersion: 1,
    pid: 4321,
    updatedAt: '2026-11-25T12:00:00.000Z',
    ok: true,
    reason: 'test',
    listenerStatus: 1,
  });
});

test('release packaging is configured with a safe, complete manifest', () => {
  const rootDir = __dirname;
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'),
  );
  const manifest = JSON.parse(
    fs.readFileSync(path.join(rootDir, 'release-manifest.json'), 'utf8'),
  );
  const changelog = fs.readFileSync(path.join(rootDir, 'CHANGELOG.md'), 'utf8');
  const forbiddenSegments = new Set([
    '.git',
    '.runtime',
    'dist',
    'logs',
    'node_modules',
  ]);

  assert.equal(
    packageJson.scripts.package,
    'powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/build-release.ps1',
  );
  assert.ok(
    new RegExp(`^## ${packageJson.version.replaceAll('.', '\\.')} - `, 'm').test(changelog),
    'package.json version must have a matching changelog entry',
  );
  assert.ok(manifest.files.includes('Control.cmd'));
  assert.ok(manifest.files.includes('keepalive.js'));
  assert.ok(manifest.files.includes('scripts/build-release.ps1'));

  for (const relativePath of manifest.files) {
    const normalizedPath = relativePath.replaceAll('\\', '/');
    const segments = normalizedPath.split('/');

    assert.ok(
      segments.every((segment) => !forbiddenSegments.has(segment)),
      `release file must not include generated data: ${relativePath}`,
    );
    assert.ok(
      fs.statSync(path.join(rootDir, normalizedPath)).isFile(),
      `release file is missing: ${relativePath}`,
    );
  }
});

test('watchdog repairs a stopped keepalive task without duplicating a healthy worker', {
  skip: process.platform !== 'win32',
}, () => {
  const testScript = path.join(__dirname, 'scripts', 'watchdog.test.ps1');

  assert.ok(fs.existsSync(testScript), 'watchdog PowerShell tests are missing');

  const result = spawnSync(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      testScript,
    ],
    {
      cwd: __dirname,
      encoding: 'utf8',
      timeout: 15_000,
    },
  );

  assert.equal(
    result.status,
    0,
    `watchdog tests failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
});
