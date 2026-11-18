"use strict";

// USB transports these messages even before either device has internet access.
// Only an actively renewed session scans/publishes; no background per-photo work.
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const https = require("node:https");
const { execFile } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const { performance } = require("node:perf_hooks");

const ID = /^[A-Za-z0-9_-]{8,80}$/;
const REQUEST = /^wifi_request_([A-Za-z0-9_-]{8,80})\.json$/;
const LEASE_MS = 20000;
const POLL_MS = 1500;
const OBSERVE_TIMEOUT_MS = 2000;
const SCAN_MS = 15000;
// DHCP 까지 마치는 데 10초를 넘는 공유기가 흔하다. NM 의 DHCP 제한(45초)보다는 짧게,
// 앱 요청 제한(120초) 안에서 두 번 시도할 수 있게 잡는다.
const VERIFY_ATTEMPTS = 13;
const VERIFY_POLL_MS = 1500;
const MAX_REQUEST_BYTES = 8192;
const STATE = {
  40: "connecting",
  50: "connecting",
  60: "connecting",
  70: "connecting",
  80: "connecting",
  90: "connecting",
  100: "connected",
  120: "failed",
};

function splitTerse(line) {
  const fields = [""];
  for (let i = 0; i < line.length; i += 1) {
    if (line[i] === "\\" && i + 1 < line.length)
      fields[fields.length - 1] += line[++i];
    else if (line[i] === ":") fields.push("");
    else fields[fields.length - 1] += line[i];
  }
  return fields;
}

function parseNetworks(stdout, saved = new Map()) {
  const bySsid = new Map();
  for (const line of String(stdout).split("\n")) {
    if (!line) continue;
    const [active, ssid, signal, security = ""] = splitTerse(line);
    if (!ssid || signal === undefined) continue; // Hidden networks use manual entry.
    const network = {
      ssid,
      signal: Math.max(0, Math.min(100, Number(signal) || 0)),
      security: security === "--" ? "" : security,
      saved: saved.has(ssid),
      connected: active === "*",
    };
    const previous = bySsid.get(ssid);
    if (!previous || network.signal > previous.signal)
      bySsid.set(ssid, {
        ...network,
        connected: network.connected || !!previous?.connected,
      });
    else previous.connected ||= network.connected;
  }
  return [...bySsid.values()].sort(
    (a, b) =>
      Number(b.connected) - Number(a.connected) ||
      b.signal - a.signal ||
      a.ssid.localeCompare(b.ssid)
  );
}

function errorCode(result) {
  const text = String(result?.stderr || "").toLowerCase();
  if (
    /not authorized|permission|not permitted|sudo:|password is required/.test(
      text
    )
  )
    return "permission_denied";
  if (
    /secrets were required|no secrets|wrong password|authentication|802-11-wireless-security/.test(
      text
    )
  )
    return "authentication_failed";
  if (
    /no network with ssid|not found|not available|no suitable device/.test(text)
  )
    return "network_not_found";
  if (result?.timedOut || /timeout|timed out/.test(text))
    return "connection_timeout";
  return "connection_failed";
}

// Never return/log Error.message: execFile adds the complete command (and secrets).
function runCommand(args, { sudo = false, timeout = 10000 } = {}) {
  return new Promise((resolve) => {
    execFile(
      sudo ? "sudo" : "nmcli",
      sudo ? ["-n", "nmcli", ...args] : args,
      {
        timeout,
        maxBuffer: 256 * 1024,
        env: { ...process.env, LC_ALL: "C", LANG: "C" },
      },
      (error, stdout, stderr) =>
        resolve({
          ok: !error,
          stdout: stdout || "",
          stderr: stderr || "",
          timedOut: !!error?.killed,
        })
    );
  });
}

function disablePowerSave(device) {
  // Preserve the existing Broadcom stability setting without cycling the radio.
  // Failure is optional; a missing iw utility must not block a normal NM connection.
  return new Promise((resolve) => {
    execFile(
      "sudo",
      ["-n", "/usr/sbin/iw", "dev", device, "set", "power_save", "off"],
      { timeout: 3000, maxBuffer: 8192 },
      () => resolve()
    );
  });
}

// Two independent endpoints: one blocked/slow CDN must not mark a working
// uplink as "limited". The first 204 wins; a redirect means a captive portal.
const PROBE_URLS = [
  "https://www.gstatic.com/generate_204",
  "https://cp.cloudflare.com/generate_204",
];

function probeOnce(url, ipv4) {
  return new Promise((resolve) => {
    let finished = false;
    let request;
    const finish = (state) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      request?.destroy();
      resolve(state);
    };
    const timer = setTimeout(() => finish("limited"), 4500);
    // Bind to Wi-Fi: an online Ethernet adapter must not mask a broken Wi-Fi link.
    request = https.get(url, { localAddress: ipv4 }, (response) => {
      const status = response.statusCode || 0;
      response.resume();
      finish(
        status === 204
          ? "online"
          : status >= 300 && status < 400
          ? "portal"
          : "limited"
      );
    });
    request.on("error", () => finish("limited"));
  });
}

async function probeInternet(ipv4) {
  if (!ipv4) return "offline";
  let outcome = "limited";
  for (const url of PROBE_URLS) {
    outcome = await probeOnce(url, ipv4);
    if (outcome === "online") return outcome;
  }
  return outcome;
}

// ponytail: single CDN (Cloudflare) and TLS on a Pi 3 caps near ~60 Mbps;
// enough to tell "usable" from "too slow" for uploads, not a lab benchmark.
const SPEED_URL = "https://speed.cloudflare.com/__down?bytes=25000000";
const SPEED_MS = 5000;

function measureDownload(ipv4) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    let started = 0;
    let finished = false;
    let request;
    let timer;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      request?.destroy();
      const seconds = (performance.now() - started) / 1000;
      // Too little data (or a refused endpoint) is not a speed; report failure.
      if (!started || bytes < 256 * 1024 || seconds <= 0)
        return reject(new Error("speed_failed"));
      resolve(Math.round((bytes * 8) / seconds / 1e5) / 10);
    };
    timer = setTimeout(finish, 4000); // connect + TLS budget
    request = https.get(SPEED_URL, { localAddress: ipv4 }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        return finish();
      }
      // Time from the first byte: DNS/TLS latency is not download throughput.
      started = performance.now();
      clearTimeout(timer);
      timer = setTimeout(finish, SPEED_MS);
      response.on("data", (chunk) => (bytes += chunk.length));
      response.on("end", finish);
      response.on("error", finish);
    });
    request.on("error", finish);
  });
}

async function readJson(fsp, filename) {
  const stat = await fsp.stat(filename);
  if (!stat.isFile() || stat.size > MAX_REQUEST_BYTES)
    throw new Error("invalid_request");
  return JSON.parse(await fsp.readFile(filename, "utf8"));
}

async function atomicJson(fsp, filename, value) {
  const temporary = `${filename}.${randomUUID()}.tmp`;
  let renamed = false;
  try {
    await fsp.writeFile(temporary, JSON.stringify(value), {
      encoding: "utf8",
      mode: 0o600,
    });
    await fsp.rename(temporary, filename);
    renamed = true;
  } finally {
    if (!renamed) await fsp.unlink(temporary).catch(() => {});
  }
}

function validSession(value) {
  return (
    value?.version === 2 &&
    typeof value.sessionId === "string" &&
    ID.test(value.sessionId) &&
    typeof value.heartbeatId === "string" &&
    ID.test(value.heartbeatId) &&
    typeof value.active === "boolean"
  );
}

function validRequest(value, fileId, sessionId) {
  if (
    value?.version !== 2 ||
    value.sessionId !== sessionId ||
    value.requestId !== fileId ||
    !ID.test(fileId)
  )
    return false;
  if (value.action === "scan" || value.action === "speedtest") return true;
  if (value.action === "radio") return typeof value.enabled === "boolean";
  if (value.action === "forget") {
    return (
      typeof value.ssid === "string" &&
      Buffer.byteLength(value.ssid) >= 1 &&
      Buffer.byteLength(value.ssid) <= 32 &&
      !/[\r\n\0]/.test(value.ssid)
    );
  }
  if (
    value.action !== "connect" ||
    typeof value.ssid !== "string" ||
    Buffer.byteLength(value.ssid) < 1 ||
    Buffer.byteLength(value.ssid) > 32 ||
    /[\r\n\0]/.test(value.ssid)
  )
    return false;
  if (
    value.password !== undefined &&
    (typeof value.password !== "string" ||
      value.password.length > 128 ||
      /[\r\n\0]/.test(value.password))
  )
    return false;
  return (
    (value.hidden === undefined || typeof value.hidden === "boolean") &&
    (value.useSaved === undefined || typeof value.useSaved === "boolean")
  );
}

function createLiveWifiService({
  fsp = fs,
  run = runCommand,
  now = () => performance.now(),
  probe = probeInternet,
  measure = measureDownload,
  powerSaveOff = disablePowerSave,
  interval = POLL_MS,
  agentName = os.hostname(),
  activity = null,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  const instanceId = randomUUID();
  const directories = new Map();
  const scans = new Set();
  let connectionOwner = null;
  let sequence = 0;

  function stateFor(directory) {
    let state = directories.get(directory);
    if (!state) {
      state = {
        directory,
        stopped: false,
        session: null,
        heartbeat: null,
        renewedAt: 0,
        processed: new Set(),
        scanAt: -Infinity,
        savedAt: -Infinity,
        saved: new Map(),
        scan: { state: "idle", networks: [] },
        connection: {
          state: "disconnected",
          ssid: null,
          ipv4: null,
          internet: "unknown",
        },
        operation: null,
        internetAt: -Infinity,
        internetKey: null,
        speed: { key: null, state: "idle", downloadMbps: null },
        radio: "on",
        radioAt: -Infinity,
        speedTask: null,
        operationTask: null,
        scanTask: null,
      };
      directories.set(directory, state);
    }
    return state;
  }

  function active(state) {
    return (
      !state.stopped &&
      !!state.session?.active &&
      now() - state.renewedAt < LEASE_MS
    );
  }

  function publish(state, force = false) {
    if (!active(state)) return Promise.resolve();
    if (state.publishTask) {
      state.publishAgain ||=
        force || state.publishingSession !== state.session.sessionId;
      return state.publishTask;
    }
    if (
      !force &&
      state.publishedSession === state.session.sessionId &&
      now() - state.publishedAt < interval
    )
      return Promise.resolve();
    state.publishingSession = state.session.sessionId;
    // At most one AFC write and one coalesced follow-up. Slow storage must not
    // build an unbounded promise queue or stop reading the app's lease.
    const task = Promise.resolve().then(async () => {
      if (!active(state)) return;
      state.publishedAt = now();
      state.publishedSession = state.session.sessionId;
      await atomicJson(fsp, path.join(state.directory, "wifi_status.json"), {
        version: 2,
        sessionId: state.session.sessionId,
        instanceId,
        sequence: ++sequence,
        agentName,
        scan: state.scan,
        connection: state.connection,
        radio: state.radio,
        speed: {
          state:
            state.speed.key === speedKey(state) ? state.speed.state : "idle",
          downloadMbps:
            state.speed.key === speedKey(state) ? state.speed.downloadMbps : null,
        },
        operation: state.operation,
      });
    });
    state.publishTask = task;
    task
      .finally(() => {
        if (state.publishTask !== task) return;
        state.publishTask = null;
        const again = state.publishAgain;
        state.publishAgain = false;
        if (again && active(state)) publish(state, true).catch(() => {});
      })
      .catch(() => {});
    return task;
  }

  async function readSession(state) {
    let session;
    try {
      session = await readJson(
        fsp,
        path.join(state.directory, "wifi_session.json")
      );
      state.sessionReadFailed = false;
    } catch {
      state.sessionReadFailed = true;
      return;
    }
    if (!validSession(session)) return null;
    if (session.sessionId !== state.session?.sessionId) {
      state.session = session;
      state.heartbeat = session.heartbeatId;
      state.renewedAt = now();
      state.processed.clear();
      state.operation = null;
      state.scanAt = -Infinity;
    } else {
      state.session = session;
      if (session.heartbeatId !== state.heartbeat) {
        state.heartbeat = session.heartbeatId;
        state.renewedAt = now();
      }
    }
    return session;
  }

  function renewActivity(state) {
    // Coordination lives on the Pi, not on AFC. Readers never enumerate the
    // iPad's photo folder to discover whether provisioning is using USB.
    if (!activity || state.activityTask) return;
    const busy = active(state) || !!state.operationTask;
    if (busy && now() - (state.activityAt ?? -Infinity) < 4000) return;
    if (!busy && !state.activityHeld) return;
    state.activityAt = now();
    state.activityHeld = busy;
    state.activityTask = Promise.resolve(
      busy ? activity.renew(state.directory) : activity.clear(state.directory)
    ).catch(() => {}).finally(() => { state.activityTask = null; });
  }

  function updateSession(state) {
    if (state.sessionTask) return state.sessionTask;
    const wasActive = active(state);
    const task = readSession(state);
    state.sessionTask = task;
    task
      .then(() => {
        renewActivity(state);
        if (!wasActive && active(state)) drive(state);
        else if (active(state)) publish(state).catch(() => {});
      })
      .catch(() => {})
      .finally(() => {
        if (state.sessionTask === task) state.sessionTask = null;
      });
    return task;
  }

  async function refreshSaved(state) {
    if (now() - state.savedAt < 30000) return;
    const result = await run([
      "-t",
      "-e",
      "yes",
      "-f",
      "UUID,TYPE",
      "connection",
      "show",
    ]);
    if (!result.ok) return;
    const saved = new Map();
    const ids = result.stdout
      .split("\n")
      .filter(Boolean)
      .map(splitTerse)
      .filter(([, type]) => type === "802-11-wireless")
      .slice(0, 100);
    // A device with years of saved APs must not serialize hundreds of processes.
    // Four workers, two seconds per read, six seconds total scheduling budget.
    const deadline = Date.now() + 6000;
    let index = 0;
    await Promise.all(
      Array.from({ length: Math.min(4, ids.length) }, async () => {
        while (index < ids.length && Date.now() < deadline) {
          const [uuid] = ids[index++];
          const details = await run(
            ["-g", "802-11-wireless.ssid", "connection", "show", "uuid", uuid],
            { timeout: 2000 }
          );
          if (details.ok) {
            const ssid = splitTerse(details.stdout.replace(/\r?\n$/, ""))[0];
            if (ssid) saved.set(ssid, uuid);
          }
        }
      })
    );
    state.saved = saved;
    state.savedAt = now();
  }

  async function readDevice(state) {
    const devices = await run(
      ["-t", "-e", "yes", "-f", "DEVICE,TYPE,STATE", "device", "status"],
      { timeout: OBSERVE_TIMEOUT_MS }
    );
    if (!devices.ok) throw new Error("agent_unavailable");
    const rows = devices.stdout
      .split("\n")
      .filter(Boolean)
      .map(splitTerse)
      .filter(([, type]) => type === "wifi");
    const row = rows.find(([, , status]) => status === "connected") || rows[0];
    if (!row) throw new Error("wifi_unavailable");
    return row[0];
  }

  async function readRadio(state) {
    if (now() - state.radioAt < 5000) return state.radio;
    const result = await run(["-t", "-f", "WIFI-HW,WIFI", "general", "status"], {
      timeout: OBSERVE_TIMEOUT_MS,
    });
    if (!result.ok) return state.radio;
    const [hardware, software] = splitTerse(result.stdout.replace(/\r?\n$/, ""));
    // 예상 밖의 출력으로 "꺼짐"을 잘못 표시하지 않는다.
    if (!["enabled", "disabled"].includes(software)) return state.radio;
    state.radioAt = now();
    state.radio =
      hardware === "disabled" ? "blocked" : software === "enabled" ? "on" : "off";
    return state.radio;
  }

  async function readObservation(state) {
    await readRadio(state).catch(() => {});
    const device = await readDevice(state);
    const details = await run(
      [
        "-t",
        "-e",
        "yes",
        "-f",
        "GENERAL.STATE,GENERAL.CON-UUID,IP4.ADDRESS",
        "device",
        "show",
        device,
      ],
      { timeout: OBSERVE_TIMEOUT_MS }
    );
    if (!details.ok) throw new Error("agent_unavailable");
    const values = new Map(
      details.stdout
        .split("\n")
        .filter(Boolean)
        .map(splitTerse)
        .map(([key, ...value]) => [key, value.join(":")])
    );
    const code = Number((values.get("GENERAL.STATE") || "").match(/^\d+/)?.[0]);
    const status = STATE[code] || "disconnected";
    const ipv4Value = [...values].find(([key]) =>
      key.startsWith("IP4.ADDRESS")
    )?.[1];
    const ipv4 =
      status === "connected" && ipv4Value ? ipv4Value.split("/")[0] : null;
    let ssid = null;
    const uuid = values.get("GENERAL.CON-UUID");
    if (status === "connected" && uuid && uuid !== "--") {
      const activeProfile = await run(
        ["-g", "802-11-wireless.ssid", "connection", "show", "uuid", uuid],
        { timeout: OBSERVE_TIMEOUT_MS }
      );
      if (activeProfile.ok)
        ssid =
          splitTerse(activeProfile.stdout.replace(/\r?\n$/, ""))[0] || null;
    }
    const internetKey = `${ssid}:${ipv4}`;
    let internet =
      internetKey === state.internetKey ? state.connection.internet : "unknown";
    state.connection = { state: status, ssid, ipv4, internet };
    state.device = device;
    if (!ipv4) {
      state.connection.internet =
        status === "connecting" ? "unknown" : "offline";
      state.internetKey = null;
    } else if (
      internetKey !== state.internetKey ||
      // Re-check quickly until online: DHCP/DNS often settle a few seconds
      // after association, and a stale "limited" is what the user sees.
      now() - state.internetAt >= (internet === "online" ? 10000 : 3000)
    ) {
      state.internetKey = internetKey;
      state.internetAt = now();
      // Do not block heartbeat/status snapshots for an internet probe.
      if (!state.probeTask) {
        state.probeTask = (async () => {
          const connectivity = await run([
            "-t",
            "-f",
            "CONNECTIVITY",
            "general",
          ]);
          const value = connectivity.stdout.trim();
          const outcome = value === "portal" ? "portal" : await probe(ipv4);
          if (state.internetKey === internetKey) {
            state.connection = { ...state.connection, internet: outcome };
            if (outcome === "online") measureSpeed(state, ipv4);
          }
        })()
          .catch(() => {})
          .finally(() => {
            state.probeTask = null;
          });
      }
    }
    state.scan = {
      ...state.scan,
      networks: state.scan.networks.map((network) => ({
        ...network,
        connected: network.ssid === ssid,
      })),
    };
  }

  // Once per app session and connection, so reopening the screen re-measures.
  function speedKey(state) {
    return state.internetKey && state.session
      ? `${state.session.sessionId}:${state.internetKey}`
      : null;
  }

  function measureSpeed(state, ipv4, force = false) {
    const key = speedKey(state);
    if (state.speedTask) return state.speedTask;
    if (!key || (!force && state.speed.key === key)) return Promise.resolve();
    state.speed = { key, state: "measuring", downloadMbps: null };
    publish(state, true).catch(() => {});
    state.speedTask = measure(ipv4)
      .then(
        (mbps) => ({ state: "done", downloadMbps: mbps }),
        () => ({ state: "failed", downloadMbps: null })
      )
      .then((result) => {
        if (state.speed.key !== key) return;
        state.speed = { key, ...result };
        publish(state, true).catch(() => {});
      })
      .finally(() => {
        state.speedTask = null;
      });
    return state.speedTask;
  }

  function observe(state) {
    if (state.observeTask) return state.observeTask;
    const previousConnection = JSON.stringify(state.connection);
    const task = (async () => {
      try {
        await readObservation(state);
      } catch (error) {
        // A failed NM read is not a failed USB link. Keep the last identity
        // but stop claiming that it is a currently verified connection.
        state.connection = {
          ...state.connection,
          state: "failed",
          internet: "unknown",
        };
        throw error;
      } finally {
        state.observeTask = null;
        if (active(state))
          publish(
            state,
            previousConnection !== JSON.stringify(state.connection)
          ).catch(() => {});
      }
    })();
    state.observeTask = task;
    return task;
  }

  async function observeAfterActivation(state) {
    // Do not verify a reconnect using an observation that began before nmcli
    // completed. The single-flight owner clears itself before its promise settles.
    if (state.observeTask) await state.observeTask.catch(() => {});
    return observe(state);
  }

  function markOperation(state, sessionId, requestId, patch) {
    if (
      state.session?.sessionId === sessionId &&
      state.operation?.requestId === requestId
    ) {
      state.operation = { ...state.operation, ...patch };
      return true;
    }
    return false;
  }

  async function scan(state, explicitRequest) {
    if (state.scanTask) return state.scanTask;
    const sessionId = state.session?.sessionId;
    state.scanTask = (async () => {
      state.scan = { ...state.scan, state: "scanning", errorCode: undefined };
      await publish(state, true).catch(() => {});
      try {
        const device = state.device || (await readDevice(state));
        const radio = await run(["radio", "wifi", "on"], { sudo: true });
        if (!radio.ok) throw new Error("permission_denied");
        const rescan = await run(
          ["device", "wifi", "rescan", "ifname", device],
          { sudo: true, timeout: 15000 }
        );
        const result = await run([
          "-t",
          "-e",
          "yes",
          "-f",
          "IN-USE,SSID,SIGNAL,SECURITY",
          "device",
          "wifi",
          "list",
          "ifname",
          device,
          "--rescan",
          "no",
        ]);
        if (!result.ok) throw new Error("scan_failed");
        await refreshSaved(state);
        state.scan = {
          state: rescan.ok ? "idle" : "failed",
          networks: parseNetworks(result.stdout, state.saved),
          ...(!rescan.ok ? { errorCode: "scan_failed" } : {}),
        };
        if (explicitRequest)
          markOperation(state, sessionId, explicitRequest.requestId, {
            state: rescan.ok ? "succeeded" : "failed",
            ...(!rescan.ok ? { errorCode: "scan_failed" } : {}),
          });
      } catch (error) {
        state.scan = {
          ...state.scan,
          state: "failed",
          errorCode: ["wifi_unavailable", "permission_denied"].includes(
            error.message
          )
            ? error.message
            : "scan_failed",
        };
        if (explicitRequest)
          markOperation(state, sessionId, explicitRequest.requestId, {
            state: "failed",
            errorCode: state.scan.errorCode,
          });
      } finally {
        state.scanAt = now();
        state.scanTask = null;
        await publish(state, true).catch(() => {});
      }
    })();
    const task = state.scanTask;
    scans.add(task);
    task.then(
      () => scans.delete(task),
      () => scans.delete(task)
    );
    return task;
  }

  async function connect(state, request) {
    const { sessionId, requestId, ssid } = request;
    const current = () =>
      active(state) && state.session?.sessionId === sessionId;
    if (!current()) return;
    if (connectionOwner) {
      markOperation(state, sessionId, requestId, {
        state: "failed",
        errorCode: "agent_busy",
      });
      return;
    }
    connectionOwner = requestId;
    try {
      // A scan may already be running when the user picks a previously visible AP.
      if (scans.size) await Promise.allSettled([...scans]);
      if (!current()) return;
      const device = state.device || (await readDevice(state));
      if (!current()) return;
      const radio = await run(["radio", "wifi", "on"], { sudo: true });
      if (!radio.ok) throw new Error("permission_denied");
      await powerSaveOff(device).catch(() => {});
      await refreshSaved(state);
      const savedUuid = state.saved.get(ssid);
      let args;
      if (request.useSaved && !request.password && savedUuid) {
        args = [
          "-w",
          "55",
          "connection",
          "up",
          "uuid",
          savedUuid,
          "ifname",
          device,
        ];
      } else {
        const security = String(
          request.security ||
            state.scan.networks.find((item) => item.ssid === ssid)?.security ||
            ""
        ).toUpperCase();
        if (/802\.1X|EAP|WEP/.test(security))
          throw new Error("unsupported_security");
        if (/WPA|SAE|RSN/.test(security) && !request.password)
          throw new Error("password_required");
        args = [
          "-w",
          "55",
          "device",
          "wifi",
          "connect",
          ssid,
          "ifname",
          device,
        ];
        if (request.password) args.push("password", request.password);
        if (request.hidden) args.push("hidden", "yes");
      }
      if (!current()) return;
      const activate = async () => {
        const result = await run(args, { sudo: true, timeout: 65000 });
        // Only bounded enums leave this function. No command, stderr or password in logs/status.
        if (!result.ok) throw new Error(errorCode(result));
        markOperation(state, sessionId, requestId, { state: "verifying" });
        await publish(state, true).catch(() => {});
        for (let attempt = 0; attempt < VERIFY_ATTEMPTS; attempt += 1) {
          if (attempt === 0) await observeAfterActivation(state);
          else await observe(state);
          if (
            state.connection.state === "connected" &&
            state.connection.ssid === ssid &&
            state.connection.ipv4
          ) {
            return true;
          }
          if (!current()) return false;
          if (attempt < VERIFY_ATTEMPTS - 1) await sleep(VERIFY_POLL_MS);
        }
        return false;
      };
      let verified = await activate();
      // 복구 스크립트나 자동 연결이 링크를 다른 프로필로 가져간 경우다. 사용자가 같은
      // 버튼을 다시 누르는 것과 같은 일을 한 번만 대신 해 준다.
      const hijacked = () =>
        state.connection.state === "connected" &&
        !!state.connection.ssid &&
        state.connection.ssid !== ssid;
      if (!verified && current() && hijacked()) {
        verified = await activate();
      }
      if (!verified) throw new Error("connection_not_verified");
      state.savedAt = -Infinity;
      state.saved.set(ssid, savedUuid || "");
      state.scan = {
        ...state.scan,
        networks: state.scan.networks.map((network) => ({
          ...network,
          saved: network.saved || network.ssid === ssid,
        })),
      };
      markOperation(state, sessionId, requestId, { state: "succeeded" });
    } catch (error) {
      const allowed = new Set([
        "agent_busy",
        "wifi_unavailable",
        "agent_unavailable",
        "permission_denied",
        "unsupported_security",
        "password_required",
        "authentication_failed",
        "network_not_found",
        "connection_timeout",
        "connection_failed",
        "connection_not_verified",
      ]);
      markOperation(state, sessionId, requestId, {
        state: "failed",
        errorCode: allowed.has(error.message)
          ? error.message
          : "connection_failed",
      });
      await observe(state).catch(() => {});
    } finally {
      request.password = undefined;
      if (connectionOwner === requestId) connectionOwner = null;
      await publish(state, true).catch(() => {});
    }
  }

  async function requests(state) {
    const sessionId = state.session.sessionId;
    const current = () =>
      active(state) && state.session?.sessionId === sessionId;
    // Modern clients point to one fully published command. Listing a photo
    // folder with thousands of entries can monopolize AFC for 10+ seconds.
    const direct = state.session.requestDiscovery === "direct";
    const pending = state.session.pendingRequestId;
    const files = direct
      ? typeof pending === "string" && ID.test(pending) && !state.processed.has(pending)
        ? [`wifi_request_${pending}.json`]
        : []
      : await fsp.readdir(state.directory);
    if (!current()) return;
    for (const file of files
      .filter((name) => REQUEST.test(name))
      .sort()
      .slice(0, 20)) {
      const requestId = REQUEST.exec(file)[1];
      const filename = path.join(state.directory, file);
      let request;
      try {
        request = await readJson(fsp, filename);
      } catch (error) {
        // The app publishes completed files. Invalid content can be removed,
        // but AFC EIO/timeouts do not prove a valid command is invalid. Preserve
        // unclaimed requests for the next read; this never replays an activation.
        if (error instanceof SyntaxError || error.message === "invalid_request")
          await fsp.unlink(filename).catch(() => {});
        continue;
      }
      if (!current()) return;
      if (request?.sessionId && request.sessionId !== sessionId) {
        // A newer app session publishes its lease before its request. A slow
        // directory listing must not consume that newer session's command.
        const latestSession = await updateSession(state);
        if (!latestSession || !current()) return;
      }
      // Consume immediately, including stale/duplicate/invalid requests: no secret backlog.
      try {
        await fsp.unlink(filename);
      } catch (error) {
        // The app can cancel/remove a request after our read (close/background/timeout).
        // Only a successful consume claims the command. A missing request is not a
        // missing USB directory, and must not terminate that directory's watcher.
        if (error.code === "ENOENT") continue;
        throw error;
      }
      if (!current()) return;
      if (state.processed.has(requestId) || request?.sessionId !== sessionId)
        continue;
      state.processed.add(requestId);
      if (state.processed.size > 128)
        state.processed.delete(state.processed.values().next().value);
      if (!validRequest(request, requestId, sessionId)) {
        state.operation = {
          requestId,
          action: ["scan", "speedtest", "radio", "forget"].includes(
            request.action
          )
            ? request.action
            : "connect",
          state: "failed",
          errorCode: "invalid_request",
        };
        publish(state, true).catch(() => {});
        continue;
      }
      if (state.operationTask) {
        // A new UI session can arrive while an earlier activation is finishing.
        // Report busy to that request instead of silently making the app wait forever.
        if (
          state.operation?.state !== "connecting" &&
          state.operation?.state !== "verifying" &&
          state.operation?.state !== "scanning"
        ) {
          state.operation = {
            requestId,
            action: request.action,
            state: "failed",
            errorCode: "agent_busy",
          };
          publish(state, true).catch(() => {});
        }
        continue;
      }
      state.operation = {
        requestId,
        action: request.action,
        state:
          request.action === "scan"
            ? "scanning"
            : request.action === "connect"
            ? "connecting"
            : "verifying",
      };
      publish(state, true).catch(() => {});
      state.operationTask = (async () => {
        if (request.action === "scan") {
          if (connectionOwner)
            markOperation(state, request.sessionId, requestId, {
              state: "failed",
              errorCode: "agent_busy",
            });
          else {
            if (state.scanTask) {
              await state.scanTask;
              markOperation(state, request.sessionId, requestId, {
                state: state.scan.state === "failed" ? "failed" : "succeeded",
                ...(state.scan.errorCode
                  ? { errorCode: state.scan.errorCode }
                  : {}),
              });
            } else await scan(state, request);
          }
        } else if (request.action === "radio") {
          const result = await run(
            ["radio", "wifi", request.enabled ? "on" : "off"],
            { sudo: true }
          );
          // 하드웨어 스위치로 꺼져 있으면 명령이 성공해도 켜지지 않는다.
          state.radioAt = -Infinity;
          const radio = await readRadio(state).catch(() => state.radio);
          const applied = result.ok && (request.enabled ? radio === "on" : radio !== "on");
          markOperation(state, request.sessionId, requestId,
            applied
              ? { state: "succeeded" }
              : {
                  state: "failed",
                  errorCode: radio === "blocked" ? "radio_blocked" : "radio_failed",
                }
          );
          if (applied && request.enabled) state.scanAt = -Infinity;
          publish(state, true).catch(() => {});
        } else if (request.action === "forget") {
          await refreshSaved(state);
          const uuid = state.saved.get(request.ssid);
          // 지금 쓰고 있는 Wi-Fi 를 지우면 그 자리에서 인터넷이 끊긴다.
          const inUse = state.connection.ssid === request.ssid;
          let result = { ok: false };
          if (uuid && !inUse) {
            result = await run(["connection", "delete", "uuid", uuid], {
              sudo: true,
              timeout: 15000,
            });
          }
          if (result.ok) {
            state.saved.delete(request.ssid);
            state.savedAt = -Infinity;
            state.scan = {
              ...state.scan,
              networks: state.scan.networks.map((network) =>
                network.ssid === request.ssid
                  ? { ...network, saved: false }
                  : network
              ),
            };
          }
          markOperation(state, request.sessionId, requestId,
            result.ok
              ? { state: "succeeded" }
              : {
                  state: "failed",
                  errorCode: inUse
                    ? "network_in_use"
                    : uuid
                    ? "forget_failed"
                    : "network_not_found",
                }
          );
          publish(state, true).catch(() => {});
        } else if (request.action === "speedtest") {
          const { internet, ipv4 } = state.connection;
          if (connectionOwner || internet !== "online" || !ipv4)
            markOperation(state, request.sessionId, requestId, {
              state: "failed",
              errorCode: connectionOwner ? "agent_busy" : "internet_unavailable",
            });
          else {
            // Manual re-run; joins an automatic measurement already in flight.
            await measureSpeed(state, ipv4, true);
            markOperation(state, request.sessionId, requestId,
              state.speed.state === "done"
                ? { state: "succeeded" }
                : { state: "failed", errorCode: "speed_failed" }
            );
          }
          publish(state, true).catch(() => {});
        } else await connect(state, request);
      })()
        .catch(() => {
          markOperation(state, request.sessionId, requestId, {
            state: "failed",
            errorCode: "agent_unavailable",
          });
        })
        .finally(() => {
          state.operationTask = null;
        });
    }
  }

  async function tick(directory) {
    const state = stateFor(directory);
    // AFC can spend 12+ seconds returning EIO for a file being rewritten by
    // iOS. Every lane is single-flight; none holds heartbeat publication hostage.
    updateSession(state).catch(() => {});
    renewActivity(state);
    drive(state);
  }

  function drive(state) {
    if (!active(state)) return;
    if (!state.requestTask) {
      const task = requests(state);
      state.requestTask = task;
      task
        .catch(() => {})
        .finally(() => {
          if (state.requestTask === task) state.requestTask = null;
          if (
            active(state) &&
            !state.operationTask &&
            !connectionOwner &&
            now() - state.scanAt >= SCAN_MS
          )
            scan(state).catch(() => {});
        });
    }
    observe(state).catch(() => {});
    publish(state).catch(() => {});
  }

  function watchDirectory(directory) {
    let state = stateFor(directory);
    if (state.loop && !state.stopped) return;
    if (state.stopped) {
      directories.delete(directory);
      state = stateFor(directory);
    }
    state.loop = (async () => {
      try {
        while (!state.stopped) {
          await tick(directory).catch(() => {});
          // Only directory metadata can prove the mount is gone. ENOENT/EIO
          // from an individual request, lease or rename cannot kill this loop.
          if (state.sessionReadFailed && !active(state) && !state.directoryTask &&
              now() >= (state.directoryCheckAt ?? -Infinity)) {
            state.directoryCheckAt = now() + 30000;
            const task = fsp
              .stat(directory)
              .then((stat) => {
                if (!stat.isDirectory()) state.stopped = true;
              })
              .catch((error) => {
                if (error.code === "ENOENT" || error.code === "ENOTDIR")
                  state.stopped = true;
              });
            state.directoryTask = task;
            task.finally(() => {
              if (state.directoryTask === task) state.directoryTask = null;
            });
          }
          await sleep(interval);
        }
      } finally {
        state.stopped = true;
        renewActivity(state);
        state.loop = null;
        if (directories.get(directory) === state) directories.delete(directory);
      }
    })();
  }

  function stopDirectory(directory) {
    const state = directories.get(directory);
    if (state) { state.stopped = true; renewActivity(state); }
  }

  async function runLegacyConnect(fn) {
    if (connectionOwner) return { busy: true };
    connectionOwner = "legacy";
    try {
      if (scans.size) await Promise.allSettled([...scans]);
      return await fn();
    } finally {
      connectionOwner = null;
    }
  }

  return {
    watchDirectory,
    stopDirectory,
    tick,
    runLegacyConnect,
    isConnecting: () => !!connectionOwner,
    isActiveDirectory: (directory) => {
      const state = directories.get(directory);
      return !!state && (active(state) || !!state.operationTask);
    },
    refreshSession: (directory) => updateSession(stateFor(directory)),
    stateFor,
  };
}

module.exports = {
  createLiveWifiService,
  parseNetworks,
  splitTerse,
  errorCode,
  validRequest,
  validSession,
  atomicJson,
  probeInternet,
  LEASE_MS,
};
