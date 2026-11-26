'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PROTOCOL = Object.freeze({
  SERVICE_MODULE_ID: 31653888,
  OFFICE_MODULE_ID: 22085632,
  START_PUBLISH: 8519682,
  START_PUBLISH_SUCCESS: 8519738,
  ALLOW_DISCOVER: 8519698,
  GET_ALLOW_DISCOVER: 8519730,
  STOP_PUBLISH: 8519753,
  RESTART_STOP_PUBLISH_TIMER: 8519754,
});

const DEFAULT_INTERVAL_MS = 60_000;
const STATUS_TIMEOUT_MS = 2_500;
const STOP_POLL_MS = 1_000;

function parseListenerStatus(payload) {
  if (typeof payload !== 'string' || payload.length === 0) {
    return null;
  }

  try {
    const parsed = JSON.parse(payload);
    return parsed.listenerstatus === 0 || parsed.listenerstatus === 1
      ? parsed.listenerstatus
      : null;
  } catch {
    return null;
  }
}

function writeHealthFile(healthPath, {
  pid = process.pid,
  reason,
  listenerStatus,
  now = new Date(),
} = {}) {
  fs.mkdirSync(path.dirname(healthPath), { recursive: true });
  fs.writeFileSync(
    healthPath,
    JSON.stringify({
      schemaVersion: 1,
      pid,
      updatedAt: now.toISOString(),
      ok: listenerStatus === 1,
      reason,
      listenerStatus,
    }, null, 2),
    'utf8',
  );
}

function createController({
  sdk,
  logger,
  intervalMs = DEFAULT_INTERVAL_MS,
  delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  schedule = setTimeout,
  clearSchedule = clearTimeout,
  dismissHonorToast = () => {},
}) {
  const pendingStatusRequests = new Set();
  let initialized = false;
  let autoRecoveryEnabled = true;
  let recoveryInFlight = null;

  function finishStatusRequests(value) {
    for (const request of pendingStatusRequests) {
      clearSchedule(request.timer);
      request.resolve(value);
    }
    pendingStatusRequests.clear();
  }

  function handleStatusResponse(payload) {
    const value = parseListenerStatus(payload);
    if (value === null) {
      logger.warn(`收到无法识别的荣耀分享状态: ${String(payload)}`);
      return;
    }

    logger.info(`荣耀分享可发现状态: ${value === 1 ? '已开启' : '已关闭'}`);
    finishStatusRequests(value);
  }

  function initialize() {
    if (initialized) {
      return;
    }

    sdk.RegisterRecvHonorShareGetReceiveListenerStatusRspMsg(handleStatusResponse);
    if (typeof sdk.RegisterRecvHonorShareCloseDiscoverMsg === 'function') {
      sdk.RegisterRecvHonorShareCloseDiscoverMsg((payload) => {
        handleUnexpectedClose('收到关闭事件', payload);
      });
    }
    if (typeof sdk.RegisterRecvHonorShareConfirmCloseDiscoverMsg === 'function') {
      sdk.RegisterRecvHonorShareConfirmCloseDiscoverMsg((payload) => {
        handleUnexpectedClose('收到关闭确认事件', payload);
      });
    }
    if (typeof sdk.RegisterRecvHonorShareStopPublishMsg === 'function') {
      sdk.RegisterRecvHonorShareStopPublishMsg((payload) => {
        handleUnexpectedClose('收到停止发布事件', payload);
      });
    }
    sdk.Init('notepadUpdate');
    initialized = true;
  }

  function startPublishing() {
    sdk.SendCommonMsgWithReply(
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.START_PUBLISH,
      PROTOCOL.START_PUBLISH_SUCCESS,
      '',
    );
  }

  function setDiscoveryEnabled(enabled) {
    sdk.SendIPCMsgWithFromModuleId(
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.ALLOW_DISCOVER,
      PROTOCOL.OFFICE_MODULE_ID,
      enabled ? '1' : '0',
    );
  }

  async function restartDiscoveryTimer() {
    sdk.SendIPCMsgWithFromModuleId(
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.RESTART_STOP_PUBLISH_TIMER,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    );
    await delay(120);
    logger.info('已重置十分钟可发现计时器，未关闭荣耀分享。');
  }

  function handleUnexpectedClose(reason, payload) {
    if (!autoRecoveryEnabled) {
      return;
    }

    logger.warn(`${reason}，立即执行无窗口恢复: ${String(payload)}`);
    try {
      dismissHonorToast();
    } catch (error) {
      logger.warn(`关闭荣耀提示窗口失败: ${error.message}`);
    }
    schedule(() => {
      recoverNow(reason, { verifyFirst: true }).catch((error) => {
        logger.error(`即时恢复失败: ${error.stack || error.message}`);
      });
    }, 0);
  }

  function recoverNow(reason, { verifyFirst = false } = {}) {
    if (recoveryInFlight) {
      return recoveryInFlight;
    }

    const startedAt = Date.now();
    const operation = (async () => {
      if (verifyFirst) {
        const observedStatus = await queryStatus(1_000);
        if (observedStatus === 1) {
          await restartDiscoveryTimer();
          const latencyMs = Date.now() - startedAt;
          logger.info(`关闭通知后确认分享仍开启，仅刷新计时器: ${reason}，耗时 ${latencyMs}ms。`);
          return {
            status: 1,
            latencyMs,
            reopened: false,
          };
        }
      }

      setDiscoveryEnabled(true);
      await restartDiscoveryTimer();
      let status = await queryStatus(1_000);

      if (status !== 1) {
        logger.warn('单独开启荣耀分享未生效，回退到重启发布流程。');
        startPublishing();
        setDiscoveryEnabled(true);
        await delay(180);
        await restartDiscoveryTimer();
        status = await queryStatus();
      }

      const latencyMs = Date.now() - startedAt;

      if (status === 1) {
        logger.info(`即时恢复成功: ${reason}，耗时 ${latencyMs}ms。`);
      } else {
        logger.warn(`即时恢复未确认开启: ${reason}，耗时 ${latencyMs}ms。`);
      }

      return {
        status,
        latencyMs,
        reopened: true,
      };
    })();

    recoveryInFlight = operation;
    operation.then(
      () => {
        if (recoveryInFlight === operation) {
          recoveryInFlight = null;
        }
      },
      () => {
        if (recoveryInFlight === operation) {
          recoveryInFlight = null;
        }
      },
    );

    return operation;
  }

  function queryStatus(timeoutMs = STATUS_TIMEOUT_MS) {
    return new Promise((resolve) => {
      const request = {
        resolve,
        timer: null,
      };

      request.timer = schedule(() => {
        pendingStatusRequests.delete(request);
        resolve(null);
      }, timeoutMs);
      pendingStatusRequests.add(request);

      try {
        sdk.SendIPCMsgWithFromModuleId(
          PROTOCOL.SERVICE_MODULE_ID,
          PROTOCOL.GET_ALLOW_DISCOVER,
          PROTOCOL.OFFICE_MODULE_ID,
          '',
        );
      } catch (error) {
        clearSchedule(request.timer);
        pendingStatusRequests.delete(request);
        logger.error(`查询荣耀分享状态失败: ${error.message}`);
        resolve(null);
      }
    });
  }

  async function enforce(reason, { ensurePublishing = false } = {}) {
    if (!initialized) {
      initialize();
    }

    logger.info(`执行荣耀分享保活检查: ${reason}`);

    if (ensurePublishing) {
      startPublishing();
      setDiscoveryEnabled(true);
      await delay(180);
    }

    await restartDiscoveryTimer();

    let status = await queryStatus();
    if (status === 1) {
      return status;
    }

    logger.warn('荣耀分享仍不可发现，立即执行恢复。');
    const recovery = await recoverNow('定时检查发现关闭');
    status = recovery.status;

    if (status === 1) {
      logger.info('荣耀分享已在重试后恢复开启。');
    } else {
      logger.warn(`本次保活未能确认开启状态，将在 ${intervalMs / 1000} 秒后重试。`);
    }

    return status;
  }

  function stopPublishing() {
    sdk.SendIPCMsgWithFromModuleId(
      PROTOCOL.SERVICE_MODULE_ID,
      PROTOCOL.STOP_PUBLISH,
      PROTOCOL.OFFICE_MODULE_ID,
      '',
    );
  }

  function setAutoRecoveryEnabled(enabled) {
    autoRecoveryEnabled = enabled;
  }

  return {
    initialize,
    enforce,
    queryStatus,
    startPublishing,
    setDiscoveryEnabled,
    stopPublishing,
    recoverNow,
    setAutoRecoveryEnabled,
  };
}

function createFileLogger(logPath) {
  fs.mkdirSync(path.dirname(logPath), { recursive: true });

  function write(level, message) {
    const timestamp = new Date().toLocaleString('zh-CN', { hour12: false });
    fs.appendFileSync(logPath, `${timestamp} [${level}] ${message}\r\n`, 'utf8');
  }

  return {
    info(message) {
      write('INFO', message);
    },
    warn(message) {
      write('WARN', message);
    },
    error(message) {
      write('ERROR', message);
    },
  };
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function acquireSingleInstanceLock(lockPath) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const file = fs.openSync(lockPath, 'wx');
      fs.writeFileSync(
        file,
        JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }),
        'utf8',
      );
      fs.closeSync(file);

      return () => {
        try {
          fs.unlinkSync(lockPath);
        } catch {
          // The lock may already have been removed during shutdown.
        }
      };
    } catch (error) {
      if (error.code !== 'EEXIST') {
        throw error;
      }

      let existingPid = null;
      try {
        const existing = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
        existingPid = existing.pid;
      } catch {
        // A partially written lock is stale.
      }

      if (isProcessAlive(existingPid)) {
        return null;
      }

      fs.rmSync(lockPath, { force: true });
    }
  }

  return null;
}

async function sleepWithStopCheck(milliseconds, stopPath) {
  const deadline = Date.now() + milliseconds;

  while (Date.now() < deadline) {
    if (fs.existsSync(stopPath)) {
      return false;
    }
    await new Promise((resolve) => setTimeout(resolve, STOP_POLL_MS));
  }

  return !fs.existsSync(stopPath);
}

async function run() {
  const rootDir = __dirname;
  const runtimeDir = path.join(rootDir, '.runtime');
  const logPath = path.join(rootDir, 'logs', 'keepalive.log');
  const lockPath = path.join(runtimeDir, 'keepalive.pid');
  const healthPath = path.join(runtimeDir, 'health.json');
  const stopPath = path.join(runtimeDir, 'stop.request');
  const nativeModulePath =
    'C:\\Program Files\\Hihonornote\\resources\\app.asar.unpacked\\dist\\Release\\HnOfficeSdk.node';
  const toastLauncher = path.join(rootDir, 'dismiss-toast-hidden.vbs');
  const wscriptPath = path.join(
    process.env.SystemRoot || 'C:\\Windows',
    'System32',
    'wscript.exe',
  );

  const logger = createFileLogger(logPath);
  if (!process.versions.electron) {
    logger.error('必须通过 Hihonornote.exe 的 ELECTRON_RUN_AS_NODE 模式运行。');
    process.exitCode = 1;
    return;
  }

  const releaseLock = acquireSingleInstanceLock(lockPath);
  if (!releaseLock) {
    logger.info('已有保活实例正在运行，本次启动已退出。');
    return;
  }

  let shuttingDown = false;
  const controller = createController({
    sdk: require(nativeModulePath),
    logger,
    dismissHonorToast() {
      const worker = spawn(
        wscriptPath,
        ['//B', '//NoLogo', toastLauncher],
        {
          detached: true,
          stdio: 'ignore',
          windowsHide: true,
        },
      );
      worker.on('error', (error) => {
        logger.warn(`启动荣耀提示窗口清理器失败: ${error.message}`);
      });
      worker.unref();
    },
  });

  function updateHealth(reason, listenerStatus) {
    writeHealthFile(healthPath, {
      pid: process.pid,
      reason,
      listenerStatus,
    });
  }

  async function shutdown(reason, { disableSharing = false } = {}) {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;

    if (disableSharing) {
      try {
        controller.setAutoRecoveryEnabled(false);
        controller.stopPublishing();
      } catch (error) {
        logger.warn(`关闭荣耀分享发布失败: ${error.message}`);
      }
    }

    releaseLock();
    logger.info(`荣耀分享保活服务已停止: ${reason}`);
  }

  process.on('SIGINT', async () => {
    await shutdown('收到 SIGINT', { disableSharing: true });
    process.exit(0);
  });
  process.on('SIGTERM', async () => {
    await shutdown('收到 SIGTERM', { disableSharing: true });
    process.exit(0);
  });

  try {
    fs.rmSync(stopPath, { force: true });
    controller.initialize();
    logger.info('荣耀分享保活服务已启动，使用原生 IPC，不创建界面。');

    await new Promise((resolve) => setTimeout(resolve, 1_600));
    const startupStatus = await controller.enforce('启动', { ensurePublishing: true });
    updateHealth('启动', startupStatus);

    while (await sleepWithStopCheck(DEFAULT_INTERVAL_MS, stopPath)) {
      try {
        const status = await controller.enforce('每分钟检查');
        updateHealth('每分钟检查', status);
      } catch (error) {
        logger.error(`保活检查异常: ${error.stack || error.message}`);
        updateHealth('检查异常', null);
      }
    }

    await shutdown('收到停止请求', { disableSharing: true });
    process.exit(0);
  } catch (error) {
    logger.error(`荣耀分享保活服务异常退出: ${error.stack || error.message}`);
    releaseLock();
    process.exit(1);
  }
}

if (require.main === module) {
  run();
}

module.exports = {
  PROTOCOL,
  createController,
  createFileLogger,
  parseListenerStatus,
  writeHealthFile,
};
