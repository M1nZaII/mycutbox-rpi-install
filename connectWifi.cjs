#!/usr/bin/env node

/**
 * MyCutBox iPad USB Wi-Fi Provisioning Watcher (CommonJS)
 * - Same GVFS AFC mount as usbPrint.cjs
 * - Watches MyCutBox for connect_wifi_YYMMDD_HHmm.json
 * - Picks only the latest connect_wifi_* (ignores completed/failed/processing)
 * - Flow: connect_wifi_* -> processing_connect_wifi_* -> completed_connected_wifi_* | failed_connect_wifi_*
 */

const fs = require("fs");
const fsp = fs.promises;
const path = require("path");
const os = require("os");
const { exec: execCb } = require("child_process");
const { promisify } = require("util");

const exec = promisify(execCb);

const GVFS_BASE = process.env.GVFS_BASE || "/run/user/1000/gvfs";
const AFC_PREFIX = "afc:host=";
// USB_APP_REL_DIR: 쉼표로 여러 개 지정 가능 (기본: 정식앱 + 키오스크)
const APP_REL_DIRS = (
  process.env.USB_APP_REL_DIR ||
  "com.mycutbox/MyCutBox,com.mycutbox.kiosk/MyCutBox"
)
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const POLL_MS_MOUNTS = 4000;
const POLL_MS_FILES = 2000;
const NMCLI_CONNECT_TIMEOUT_MS = Math.max(
  15000,
  Number(process.env.CONNECT_WIFI_NMCLI_TIMEOUT_MS || 60000) || 60000
);
const WIFI_CONNECT_WAIT_MS = Math.max(
  3000,
  Number(process.env.CONNECT_WIFI_WAIT_MS || 12000) || 12000
);
const WIFI_VERIFY_POLL_MS = Math.max(
  500,
  Number(process.env.CONNECT_WIFI_VERIFY_POLL_MS || 2000) || 2000
);
const WIFI_VERIFY_ATTEMPTS = Math.max(
  3,
  Number(process.env.CONNECT_WIFI_VERIFY_ATTEMPTS || 8) || 8
);

const CONNECT_RE = /^connect_wifi_(\d{6}_\d{4})\.json$/i;
const STAMP_RE = /(\d{6}_\d{4})\.json$/i;
const PROCESSING_PREFIX = "processing_connect_wifi_";
const COMPLETED_PREFIX = "completed_connected_wifi_";
const FAILED_PREFIX = "failed_connect_wifi_";
// 누락(dropped): 실패(failed)와 구분. 연결을 시도하지 못하고 버려진 요청 —
// (a) 더 최신 요청에 의해 대체된 오래된 connect_wifi_*, (b) 에이전트 재시작으로
// 중단된 processing_* — 을 표시. 비밀번호는 저장하지 않는다.
const DROPPED_PREFIX = "dropped_connect_wifi_";

const watchers = new Map();

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function fileExists(p) {
  try {
    await fsp.access(p, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function safeRename(src, dest) {
  if (await fileExists(dest)) {
    const dir = path.dirname(dest);
    const base = path.basename(dest);
    const alt = path.join(dir, `${Date.now()}_${base}`);
    await fsp.rename(src, alt);
    return alt;
  }
  await fsp.rename(src, dest);
  return dest;
}

function parseConnectStamp(fileName) {
  const m = CONNECT_RE.exec(fileName);
  return m ? m[1] : null;
}

// 어떤 job 파일(connect_/processing_/completed_/failed_/dropped_)이든 YYMMDD_HHmm 추출
function extractStamp(fileName) {
  const m = STAMP_RE.exec(fileName);
  return m ? m[1] : null;
}

// 요청을 "누락(dropped)"으로 표시: 원본(있으면)을 읽어 비밀번호를 지우고 dropped_ 마커를
// 남긴 뒤 원본을 삭제한다. 실패(failed)와 달리 연결 시도 자체가 없었음을 뜻한다.
async function writeDroppedMeta(absDir, srcName, stamp, reason) {
  const srcPath = path.join(absDir, srcName);
  let base = {};
  try {
    const parsed = JSON.parse(await fsp.readFile(srcPath, "utf8"));
    if (parsed && typeof parsed === "object") base = parsed;
  } catch (_) {
    // 원본이 없거나 깨졌어도 누락 마커는 남긴다
  }
  if (base && typeof base === "object") delete base.password;
  const droppedName = `${DROPPED_PREFIX}${stamp}.json`;
  const droppedPath = path.join(absDir, droppedName);
  const payload = {
    ...base,
    version: base.version || 1,
    droppedAt: new Date().toISOString(),
    reason,
  };
  try {
    await fsp.writeFile(droppedPath, JSON.stringify(payload, null, 2), "utf8");
  } catch (e) {
    console.warn(`[Drop] failed to write ${droppedName}:`, e.message || e);
  }
  try {
    await fsp.unlink(srcPath);
  } catch (_) {}
  return droppedPath;
}

// #1: 최신보다 오래된 connect_wifi_* 는 대체된 요청 → 누락 처리(비밀번호 파일 잔존 방지).
async function sweepSupersededConnectFiles(absDir, processedStamp) {
  let files;
  try {
    files = await fsp.readdir(absDir);
  } catch {
    return;
  }
  for (const f of files) {
    if (!CONNECT_RE.test(f)) continue;
    const stamp = parseConnectStamp(f);
    if (!stamp) continue;
    // 방금 처리한 것보다 최신이거나 같으면 그대로 둔다(경쟁적으로 새 요청이 들어온 경우 보호)
    if (processedStamp && stamp.localeCompare(processedStamp) >= 0) continue;
    console.log(`[Drop] superseded ${f} -> ${DROPPED_PREFIX}${stamp}.json`);
    await writeDroppedMeta(absDir, f, stamp, "superseded by a newer connect_wifi request");
  }
}

// #2: 시작 시 남아 있는 processing_* 는 이전 실행이 연결 도중 중단된 흔적 → 누락 처리
// (평문 비밀번호가 남지 않도록 하고, 앱에는 실패가 아닌 "누락"으로 표시).
async function sweepStaleProcessingFiles(absDir) {
  let files;
  try {
    files = await fsp.readdir(absDir);
  } catch {
    return;
  }
  for (const f of files) {
    if (!f.startsWith(PROCESSING_PREFIX)) continue;
    const stamp = extractStamp(f);
    if (!stamp) continue;
    console.log(`[Drop] stale processing ${f} -> ${DROPPED_PREFIX}${stamp}.json (agent restart)`);
    await writeDroppedMeta(absDir, f, stamp, "interrupted before completion (agent restart)");
  }
}

function pickLatestConnectWifiFile(files) {
  const candidates = files
    .filter((f) => CONNECT_RE.test(f))
    .map((f) => ({ name: f, stamp: parseConnectStamp(f) || "" }))
    .filter((x) => x.stamp)
    .sort((a, b) => b.stamp.localeCompare(a.stamp));
  return candidates.length > 0 ? candidates[0].name : null;
}

async function readJobJson(absPath) {
  const raw = await fsp.readFile(absPath, "utf8");
  const parsed = JSON.parse(raw);
  const ssid = typeof parsed?.ssid === "string" ? parsed.ssid.trim() : "";
  const password =
    typeof parsed?.password === "string" ? parsed.password : "";
  if (!ssid) {
    throw new Error("Missing or empty ssid in JSON");
  }
  if (!password) {
    throw new Error("Missing or empty password in JSON");
  }
  return { ssid, password, rawMeta: parsed };
}

async function runNmcli(args) {
  const cmd = `nmcli ${args}`;
  try {
    const { stdout, stderr } = await exec(cmd, {
      timeout: NMCLI_CONNECT_TIMEOUT_MS,
    });
    return { ok: true, stdout, stderr, cmd };
  } catch (err) {
    return {
      ok: false,
      stdout: err.stdout || "",
      stderr: err.stderr || err.message || String(err),
      cmd,
    };
  }
}

async function ensureWifiRadioOn() {
  await runNmcli("networking on");
  await runNmcli("radio wifi on");
  await disableWifiPowerSave();
}

// brcmfmac (this Pi's onboard Broadcom wifi) has a well-documented issue where power
// save mode drops the radio mid-association — confirmed live via NetworkManager logs
// showing "associating -> disconnected" within ~0.3s on every single retry, regardless
// of PMF/band/MAC/timeout. None of those were ever the actual problem.
async function disableWifiPowerSave() {
  const res = await runShell("sudo -n iw dev wlan0 set power_save off");
  if (!res.ok) {
    console.warn(`[WiFi] could not disable power_save: ${nmcliErrorText(res)}`);
  }
}

function normalizeSsid(value) {
  return String(value || "").trim();
}

function ssidMatches(observed, expected) {
  const a = normalizeSsid(observed);
  const b = normalizeSsid(expected);
  if (!a || !b) return false;
  return a === b;
}

async function listWifiDevices() {
  const res = await runNmcli("-t -f DEVICE,TYPE device status");
  if (!res.ok) return [];
  return String(res.stdout || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const idx = line.indexOf(":");
      if (idx <= 0) return null;
      return {
        device: line.slice(0, idx),
        type: line.slice(idx + 1),
      };
    })
    .filter((row) => row && row.type === "wifi")
    .map((row) => row.device);
}

async function readSsidFromWifiDevice(device) {
  const res = await runNmcli(`-g GENERAL.CONNECTION device show ${shellQuote(device)}`);
  if (!res.ok) return "";
  const value = normalizeSsid(res.stdout);
  if (!value || value === "--") return "";
  return value;
}

// #3: 검증 폴링용 저비용 경로 — 연결된 AP는 `device wifi list` 에서 IN-USE=* 로 표시된다.
// nmcli 1회 호출(스캔 안 함)로 대부분의 경우를 커버하고, 비면 무거운 full 경로로 폴백한다.
async function readActiveWifiSsidsFast() {
  const ssids = new Set();
  const res = await runNmcli("-t -f IN-USE,SSID device wifi list --rescan no");
  if (res.ok) {
    for (const line of String(res.stdout || "").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const idx = trimmed.indexOf(":");
      if (idx < 0) continue;
      const inUse = trimmed.slice(0, idx);
      const ssid = normalizeSsid(trimmed.slice(idx + 1));
      if (
        (inUse === "*" || inUse.toLowerCase() === "yes" || inUse === "예") &&
        ssid
      ) {
        ssids.add(ssid);
      }
    }
  }
  return [...ssids];
}

async function readActiveWifiSsids() {
  const fast = await readActiveWifiSsidsFast();
  if (fast.length > 0) return fast;
  return readActiveWifiSsidsFull();
}

async function readActiveWifiSsidsFull() {
  const ssids = new Set();

  const wifiDevices = await listWifiDevices();
  for (const device of wifiDevices) {
    const ssid = await readSsidFromWifiDevice(device);
    if (ssid) ssids.add(ssid);
  }

  // device wifi list: connected AP is marked with IN-USE=* (not ACTIVE=yes)
  const listRes = await runNmcli("-t -f IN-USE,SSID device wifi list");
  if (listRes.ok) {
    for (const line of String(listRes.stdout || "").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const idx = trimmed.indexOf(":");
      if (idx < 0) continue;
      const inUse = trimmed.slice(0, idx);
      const ssid = normalizeSsid(trimmed.slice(idx + 1));
      if (
        (inUse === "*" ||
          inUse.toLowerCase() === "yes" ||
          inUse === "예") &&
        ssid
      ) {
        ssids.add(ssid);
      }
    }
  }

  // Legacy/locale: device wifi may expose ACTIVE=예/yes instead of IN-USE
  const legacyRes = await runNmcli("-t -f ACTIVE,SSID device wifi");
  if (legacyRes.ok) {
    for (const line of String(legacyRes.stdout || "").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const idx = trimmed.indexOf(":");
      if (idx < 0) continue;
      const active = trimmed.slice(0, idx);
      const ssid = normalizeSsid(trimmed.slice(idx + 1));
      if (
        (active === "*" ||
          active.toLowerCase() === "yes" ||
          active === "예") &&
        ssid
      ) {
        ssids.add(ssid);
      }
    }
  }

  const activeRes = await runNmcli("-t -f NAME,TYPE connection show --active");
  if (activeRes.ok) {
    for (const line of String(activeRes.stdout || "").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const parts = trimmed.split(":");
      if (parts.length < 2) continue;
      const name = normalizeSsid(parts[0]);
      const type = normalizeSsid(parts.slice(1).join(":")).toLowerCase();
      if (name && type.includes("wireless")) {
        ssids.add(name);
      }
    }
  }

  return [...ssids];
}

async function isWifiDeviceConnected() {
  const wifiDevices = await listWifiDevices();
  for (const device of wifiDevices) {
    const res = await runNmcli(`-g GENERAL.STATE device show ${shellQuote(device)}`);
    if (!res.ok) continue;
    const state = normalizeSsid(res.stdout).toLowerCase();
    if (
      state.includes("connected") ||
      state.includes("연결") ||
      state.startsWith("100")
    ) {
      return true;
    }
  }
  return false;
}

async function isWifiConnected(ssid) {
  const target = normalizeSsid(ssid);
  if (!target) return false;
  const activeSsids = await readActiveWifiSsids();
  return activeSsids.some((observed) => ssidMatches(observed, target));
}

async function waitForWifiConnected(ssid) {
  const attempts = Math.max(
    1,
    Math.ceil(WIFI_CONNECT_WAIT_MS / WIFI_VERIFY_POLL_MS)
  );
  const maxAttempts = Math.max(attempts, WIFI_VERIFY_ATTEMPTS);

  for (let i = 0; i < maxAttempts; i += 1) {
    if (await isWifiConnected(ssid)) {
      return { ok: true, observed: await readActiveWifiSsids() };
    }
    if (i < maxAttempts - 1) {
      await sleep(WIFI_VERIFY_POLL_MS);
    }
  }

  const observed = await readActiveWifiSsids();
  if (observed.length === 0 && (await isWifiDeviceConnected())) {
    // Connected, but SSID property not surfaced yet — avoid false failure.
    return { ok: true, observed, assumed: true };
  }

  return { ok: false, observed };
}

async function runShell(cmd, timeoutMs = NMCLI_CONNECT_TIMEOUT_MS) {
  try {
    const { stdout, stderr } = await exec(cmd, { timeout: timeoutMs });
    return { ok: true, stdout, stderr, cmd };
  } catch (err) {
    return {
      ok: false,
      stdout: err.stdout || "",
      stderr: err.stderr || err.message || String(err),
      cmd,
    };
  }
}

// System-profile ops must stay on sudo. Falling back to user nmcli makes
// NetworkManager pop the desktop "Authentication required" dialog and hang.
async function runNmcliSudo(args, timeoutMs = NMCLI_CONNECT_TIMEOUT_MS) {
  return runShell(`sudo -n nmcli ${args}`, timeoutMs);
}

async function runNmcliAny(args, timeoutMs = NMCLI_CONNECT_TIMEOUT_MS) {
  const sudo = await runNmcliSudo(args, timeoutMs);
  if (sudo.ok) return sudo;
  return runShell(`nmcli ${args}`, timeoutMs);
}

function nmcliErrorText(res) {
  return `${res?.stderr || ""}\n${res?.stdout || ""}`.trim();
}

async function withPasswdFile(password, fn) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "mcb-wifi-"));
  const file = path.join(dir, "passwd");
  try {
    // Both aliases — some NM builds only accept 802-11-wireless-security.psk in passwd-file.
    await fsp.writeFile(
      file,
      `802-11-wireless-security.psk:${password}\nwifi-sec.psk:${password}\n`,
      { mode: 0o600 }
    );
    return await fn(file);
  } finally {
    try {
      await fsp.unlink(file);
    } catch (_) {}
    try {
      await fsp.rmdir(dir);
    } catch (_) {}
  }
}

// nmcli -t escapes ":" and "\" as "\:" / "\\". Split into fields after unescaping.
function splitNmcliTerse(line) {
  const parts = [];
  let cur = "";
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === "\\" && i + 1 < line.length) {
      cur += line[i + 1];
      i += 1;
      continue;
    }
    if (ch === ":") {
      parts.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}

// Scan SECURITY (+ optional BSSID) for the target SSID.
// Default terse mode escapes BSSID colons (AA\:BB\:...); naive split() misses the AP.
async function detectWifiAp(ssid) {
  const target = normalizeSsid(ssid);
  const res = await runNmcliAny(
    "-t -e yes -f SSID,SECURITY,BSSID,SIGNAL device wifi list --rescan no"
  );
  if (!res.ok) {
    return { found: false, security: "", bssid: "", signal: 0, scanSsids: [] };
  }

  let best = null;
  const scanSsids = [];
  for (const line of String(res.stdout || "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const parts = splitNmcliTerse(trimmed);
    if (parts.length < 4) continue;

    const observed = normalizeSsid(parts[0]);
    const security = normalizeSsid(parts[1]);
    const bssid = normalizeSsid(parts[2]);
    const signal = Number(parts[parts.length - 1]);
    if (observed) scanSsids.push(observed);
    if (!ssidMatches(observed, target)) continue;

    const row = {
      found: true,
      security,
      bssid: /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(bssid) ? bssid : "",
      signal: Number.isFinite(signal) ? signal : 0,
    };
    if (!best || row.signal > best.signal) best = row;
  }

  return best || { found: false, security: "", bssid: "", signal: 0, scanSsids };
}

// NM wifi-sec.pmf: 0=default 1=disable 2=optional 3=required
// Samsung hotspots often need PMF optional/required; wrong PMF → associating→disconnected,
// after which NM wrongly "asks for new secrets" (GUI password dialog).
function authCandidatesForSecurity(security) {
  const s = String(security || "").toUpperCase();
  // WPA2-only (typical Samsung hotspot) — never try SAE; PMF disable first.
  if (s.includes("WPA2") && !s.includes("WPA3")) {
    return [
      { keyMgmt: "wpa-psk", pmf: 1 },
      { keyMgmt: "wpa-psk", pmf: 2 },
      { keyMgmt: "wpa-psk", pmf: 0 },
    ];
  }
  if (s.includes("WPA3") || s.includes("SAE")) {
    return [
      { keyMgmt: "sae", pmf: 3 },
      { keyMgmt: "wpa-psk", pmf: 2 },
      { keyMgmt: "wpa-psk", pmf: 1 },
    ];
  }
  if (s.includes("WPA") || s.includes("RSN")) {
    return [
      { keyMgmt: "wpa-psk", pmf: 1 },
      { keyMgmt: "wpa-psk", pmf: 2 },
      { keyMgmt: "wpa-psk", pmf: 0 },
    ];
  }
  return [
    { keyMgmt: "wpa-psk", pmf: 1 },
    { keyMgmt: "wpa-psk", pmf: 2 },
  ];
}

async function deleteWifiConnectionsNamed(ssid) {
  const list = await runNmcliSudo("-t -f NAME,UUID,TYPE connection show");
  if (!list.ok) return;
  const target = normalizeSsid(ssid);
  for (const line of String(list.stdout || "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const parts = trimmed.split(":");
    if (parts.length < 3) continue;
    const name = normalizeSsid(parts[0]);
    const uuid = normalizeSsid(parts[1]);
    const type = normalizeSsid(parts.slice(2).join(":")).toLowerCase();
    if (!type.includes("wireless") && type !== "802-11-wireless") continue;
    if (!ssidMatches(name, target)) continue;
    if (!uuid) continue;
    console.log(`[WiFi] deleting stale connection ${name} (${uuid})`);
    await runNmcliSudo(`connection delete uuid ${shellQuote(uuid)}`);
  }
}

const WIFI_SCAN_ATTEMPTS = Math.max(
  3,
  Number(process.env.CONNECT_WIFI_SCAN_ATTEMPTS || 8) || 8
);
const WIFI_SCAN_INTERVAL_MS = Math.max(
  1000,
  Number(process.env.CONNECT_WIFI_SCAN_INTERVAL_MS || 3000) || 3000
);

// Samsung hotspots often miss a single active scan (doze / 5GHz). Retry until visible.
async function waitForWifiApInScan(ssid) {
  let lastScanSsids = [];
  for (let i = 1; i <= WIFI_SCAN_ATTEMPTS; i += 1) {
    await runNmcliSudo("device wifi rescan");
    await sleep(WIFI_SCAN_INTERVAL_MS);
    const ap = await detectWifiAp(ssid);
    if (ap.scanSsids?.length) lastScanSsids = ap.scanSsids;
    // found=true is enough — do not require BSSID parse success
    if (ap.found) {
      console.log(
        `[WiFi] found in scan (try ${i}/${WIFI_SCAN_ATTEMPTS}): ` +
          `SECURITY=${ap.security || "?"} BSSID=${ap.bssid || "(none)"} SIGNAL=${ap.signal}`
      );
      return ap;
    }
    console.log(
      `[WiFi] SSID "${ssid}" not in scan yet (try ${i}/${WIFI_SCAN_ATTEMPTS})`
    );
  }
  const sample = [...new Set(lastScanSsids)].slice(0, 12).join(" | ");
  if (sample) {
    console.warn(`[WiFi] scan SSIDs seen (sample): ${sample}`);
  } else {
    console.warn(`[WiFi] scan list was empty across all attempts`);
  }
  return null;
}

// A real successful connect on this network (Samsung hotspot, earlier today) took 43s
// inside a 45s window to finish the handshake + DHCP. A shorter cap doesn't make
// connecting faster — it just gives up before the handshake would have finished.
function connectWaitSec() {
  return Math.max(
    15,
    Math.floor(Math.min(NMCLI_CONNECT_TIMEOUT_MS, 45000) / 1000)
  );
}

const MAX_WIFI_CONNECT_ATTEMPTS = Math.max(
  1,
  Number(process.env.CONNECT_WIFI_MAX_ATTEMPTS || 3) || 3
);

function pmfToKeyfile(pmf) {
  if (pmf === 1) return "disable";
  if (pmf === 2) return "optional";
  if (pmf === 3) return "required";
  return "default";
}

// NM 1.52+ rejects `device wifi connect`. Use connection add (load does not register
// the profile name on some Pi/NM builds — modify then fails with "unknown connection").
//
// wifi.cloned-mac-address permanent: a same-real-MAC block was a plausible theory for
// one hotspot, but it turned out not to hold up — a stable MAC has since connected fine
// there via the quick-connect path (which never overrides the MAC). A MAC that changes
// on every single retry is a more plausible thing for a phone hotspot's own anti-abuse
// heuristics to flag as many different "new" devices, so keep it stable instead.
//
// pairwise/group ccmp: force CCMP-only, no TKIP. wpa_supplicant's AUTO cipher
// negotiation doesn't always land cleanly on iOS Personal Hotspot, which is strict
// about this — pinning it removes one axis of ambiguity from the handshake.
async function installWifiProfile(ssid, password, keyMgmt, pmf, band) {
  await deleteWifiConnectionsNamed(ssid);
  const label = `${keyMgmt}/pmf=${pmfToKeyfile(pmf)}`;
  console.log(
    `[WiFi] creating profile (${label}${band ? ` band=${band}` : ""})`
  );

  let addArgs =
    `connection add type wifi con-name ${shellQuote(ssid)} ` +
    `ifname '*' ssid ${shellQuote(ssid)} ` +
    `autoconnect yes ` +
    `wifi.cloned-mac-address permanent ` +
    `802-11-wireless.powersave 2 ` +
    `802-11-wireless-security.key-mgmt ${keyMgmt} ` +
    `802-11-wireless-security.pmf ${pmf} ` +
    `802-11-wireless-security.pairwise ccmp ` +
    `802-11-wireless-security.group ccmp ` +
    `802-11-wireless-security.psk ${shellQuote(password)} ` +
    `802-11-wireless-security.psk-flags 0`;
  if (band) {
    addArgs += ` 802-11-wireless.band ${band}`;
  }

  const add = await runNmcliSudo(addArgs);
  if (!add.ok) {
    return add;
  }

  return ensureProfileSecrets(ssid, password, keyMgmt, pmf, band);
}

async function ensureProfileSecrets(ssid, password, keyMgmt, pmf, band) {
  return runNmcliSudo(
    `connection modify ${shellQuote(ssid)} ` +
      `wifi.cloned-mac-address permanent ` +
      `802-11-wireless.powersave 2 ` +
      `802-11-wireless-security.key-mgmt ${keyMgmt} ` +
      `802-11-wireless-security.pmf ${pmf} ` +
      `802-11-wireless-security.pairwise ccmp ` +
      `802-11-wireless-security.group ccmp ` +
      `802-11-wireless-security.psk ${shellQuote(password)} ` +
      `802-11-wireless-security.psk-flags 0` +
      (band ? ` 802-11-wireless.band ${band}` : "")
  );
}

async function connectionProfileExists(ssid) {
  const res = await runNmcliSudo("-t -f NAME connection show");
  if (!res.ok) return false;
  const target = normalizeSsid(ssid);
  return String(res.stdout || "")
    .split("\n")
    .some((line) => ssidMatches(normalizeSsid(line), target));
}

async function readProfileKeyMgmt(ssid) {
  for (const field of [
    "wifi-sec.key-mgmt",
    "802-11-wireless-security.key-mgmt",
  ]) {
    const res = await runNmcliSudo(
      `-g ${field} connection show ${shellQuote(ssid)}`
    );
    const value = normalizeSsid(res.stdout);
    if (value && value !== "--") {
      return value;
    }
  }
  return "";
}

async function disconnectWifiDevice() {
  const devices = await listWifiDevices();
  for (const dev of devices) {
    await runNmcliSudo(`device disconnect ${shellQuote(dev)}`);
  }
}

// Headless sudo nmcli has no secrets agent, so the plain (no passwd-file) attempt
// never actually succeeds — every field log shows it burning its full wait and then
// falling through to passwd-file anyway. Go straight to passwd-file to stop paying
// that wait twice per candidate.
async function activateWifiConnection(ssid, password) {
  const waitSec = connectWaitSec();
  const name = shellQuote(ssid);
  return withPasswdFile(password, async (passwdFile) => {
    console.log(`[WiFi] connection up (wait=${waitSec}s)`);
    const args =
      `-w ${waitSec} connection up ${name} ` +
      `passwd-file ${shellQuote(passwdFile)}`;
    return runNmcliSudo(args, (waitSec + 15) * 1000);
  });
}

async function connectWithExplicitKeyMgmt(ssid, password, knownAp) {
  const ap = knownAp || (await waitForWifiApInScan(ssid));
  if (!ap) {
    return {
      ok: false,
      stdout: "",
      stderr:
        `Wi-Fi SSID "${ssid}" not found in scan after ${WIFI_SCAN_ATTEMPTS} attempts. ` +
        `For Samsung hotspots: keep the phone awake, stay near the Pi, and set the hotspot band to 2.4 GHz (or WPA2-PSK) if the Pi has no/weak 5 GHz.`,
      cmd: "nmcli device wifi list",
    };
  }

  const sec = String(ap.security || "").toUpperCase();
  const isWpa2Only = sec.includes("WPA2") && !sec.includes("WPA3");
  // pmf=optional + band=bg together is the one combination confirmed to actually work
  // (Samsung hotspot, verified live) — try it first, not buried behind other guesses
  // that could exhaust the MAX_WIFI_CONNECT_ATTEMPTS budget before reaching it.
  let candidates = isWpa2Only
    ? [
        { keyMgmt: "wpa-psk", pmf: 2, band: "bg" },
        { keyMgmt: "wpa-psk", pmf: 1, band: "" },
        { keyMgmt: "wpa-psk", pmf: 0, band: "" },
      ]
    : authCandidatesForSecurity(ap.security).map((auth) => ({ ...auth, band: "" }));
  candidates = candidates.slice(0, MAX_WIFI_CONNECT_ATTEMPTS);
  let lastError = "";

  await disconnectWifiDevice();

  for (const { keyMgmt, pmf, band } of candidates) {
    const label = `${keyMgmt}/pmf=${pmfToKeyfile(pmf)}${band ? `/band=${band}` : ""}`;

    const imported = await installWifiProfile(
      ssid,
      password,
      keyMgmt,
      pmf,
      band
    );
    if (!imported.ok) {
      lastError = nmcliErrorText(imported) || `profile install failed (${label})`;
      console.warn(`[WiFi] profile install failed (${label}):`, lastError);
      continue;
    }

    if (!(await connectionProfileExists(ssid))) {
      lastError = `profile not found after install (${label})`;
      console.warn(`[WiFi] ${lastError}`);
      continue;
    }

    const observedKeyMgmt = await readProfileKeyMgmt(ssid);
    if (observedKeyMgmt) {
      console.log(`[WiFi] profile key-mgmt=${observedKeyMgmt}`);
    } else {
      console.warn(
        `[WiFi] key-mgmt field empty after install/modify; proceeding with connection up (${label})`
      );
    }

    await runNmcliSudo("device wifi rescan");
    await sleep(1500);
    const fresh = await detectWifiAp(ssid);
    if (!fresh.found) {
      lastError = `SSID "${ssid}" disappeared from scan before associate`;
      console.warn(`[WiFi] ${lastError}`);
      await disconnectWifiDevice();
      continue;
    }

    const attempt = await activateWifiConnection(ssid, password);
    if (attempt.ok) {
      return {
        ok: true,
        stdout: attempt.stdout || `connected via keyfile ${label}`,
        stderr: attempt.stderr || "",
        cmd: attempt.cmd,
        keyMgmt,
        pmf,
      };
    }

    lastError = nmcliErrorText(attempt) || `connect failed (${label})`;
    console.warn(`[WiFi] connect failed (${label}):`, lastError);
    await disconnectWifiDevice();
    await sleep(1000);
  }

  return {
    ok: false,
    stdout: "",
    stderr:
      `Could not connect to "${ssid}" after ${candidates.length} attempt(s): ` +
      (lastError || "wifi connect failed") +
      ` | scanned SECURITY=${ap.security || "?"}. ` +
      `Association timeout often triggers a false "wrong password" GUI dialog — password may be correct. ` +
      `Try Samsung hotspot: WPA2-PSK + 2.4GHz only, screen on.`,
    cmd: "nmcli connection add / connection up",
  };
}

// The one-shot `nmcli device wifi connect` path — exactly the command the old,
// confirmed-working connectWifi.cjs used. No `-w` cap: NM handles its own internal
// retry behavior during association, and forcing a short deadline on it (10-45s,
// tried both) reproduced a clean full-duration timeout every time — that attempt
// needs more room than a hard cap gives it. Only the exec-level
// NMCLI_CONNECT_TIMEOUT_MS (60s) bounds it. `device wifi connect` still resolves
// security type from NM's own scan cache though, so the caller must confirm the
// SSID is already present there (waitForWifiApInScan) — otherwise this fails
// instantly with "No network with SSID found" / "key-mgmt: property is missing"
// without ever attempting a connection. Manually built connection profiles
// (PMF/MAC/psk-flag overrides) turned out less reliable for some networks, so this
// runs first and the profile-based candidate loop is now only a fallback.
//
// Always sudo, never plain `nmcli` first: this is a headless kiosk flow with nobody
// at the screen, but on a desktop running a graphical polkit agent (confirmed live:
// polkit-mate-authentication-agent-1), an unprivileged nmcli call that needs to
// create/activate a connection triggers a real "Authentication Required" GUI prompt
// that then sits there forever unanswered. Running as root via sudo from the start
// never needs polkit at all.
async function tryQuickConnect(ssid, password) {
  const connectCmd = `device wifi connect ${shellQuote(ssid)} password ${shellQuote(password)}`;
  return runNmcliSudo(connectCmd, NMCLI_CONNECT_TIMEOUT_MS);
}

// If we already have a profile for this SSID (from a previous successful connect),
// just refresh its password and bring it up directly — no delete/rebuild/MAC-reroll
// churn. Falls through to the full quick-connect + candidate-loop flow if this fails
// (e.g. the network's password changed since we last connected).
async function tryExistingProfile(ssid, password) {
  if (!(await connectionProfileExists(ssid))) return null;
  console.log(`[WiFi] "${ssid}" already registered — connecting directly`);
  const modify = await runNmcliSudo(
    `connection modify ${shellQuote(ssid)} 802-11-wireless-security.psk ${shellQuote(password)}`
  );
  if (!modify.ok) return modify;

  const waitSec = connectWaitSec();
  return withPasswdFile(password, async (passwdFile) => {
    const args =
      `-w ${waitSec} connection up ${shellQuote(ssid)} ` +
      `passwd-file ${shellQuote(passwdFile)}`;
    return runNmcliSudo(args, (waitSec + 15) * 1000);
  });
}

async function attemptConnectWifi(ssid, password) {
  await ensureWifiRadioOn();

  let attempt = await tryExistingProfile(ssid, password);

  if (!attempt || !attempt.ok) {
    if (attempt) {
      console.warn(
        `[WiFi] existing profile connect failed: ${nmcliErrorText(attempt)}; trying fresh`
      );
    }

    const ap = await waitForWifiApInScan(ssid);
    if (!ap) {
      throw new Error(
        `Wi-Fi SSID "${ssid}" not found in scan after ${WIFI_SCAN_ATTEMPTS} attempts.`
      );
    }

    console.log(`[WiFi] connecting "${ssid}" (quick connect)`);
    attempt = await tryQuickConnect(ssid, password);

    if (!attempt.ok) {
      console.warn(
        `[WiFi] quick connect failed: ${nmcliErrorText(attempt)}; falling back to profile-based retry`
      );
      console.log(
        `[WiFi] connecting "${ssid}" (scan → connection add → connection up)`
      );
      attempt = await connectWithExplicitKeyMgmt(ssid, password, ap);
    }
  }

  if (!attempt.ok) {
    throw new Error(nmcliErrorText(attempt) || "nmcli wifi connect failed");
  }

  const verify = await waitForWifiConnected(ssid);
  if (!verify.ok) {
    const observedText =
      verify.observed.length > 0 ? verify.observed.join(", ") : "(none)";
    throw new Error(
      `nmcli connect succeeded but SSID "${ssid}" not verified (observed: ${observedText})`
    );
  }

  const detail = attempt.stdout.trim() || "connected";
  if (verify.assumed) {
    console.log(
      `[Verify] wlan connected; SSID field not ready yet for "${ssid}" (trusting nmcli success)`
    );
  } else if (verify.observed?.length) {
    console.log(`[Verify] active SSID(s): ${verify.observed.join(", ")}`);
  }
  return { ok: true, detail };
}

// A field issue traced (live) to the wifi radio/driver itself accumulating stuck
// state after heavy connect/disconnect churn — confirmed by direct comparison:
// `systemctl restart NetworkManager` alone (daemon-level) did NOT reliably clear it,
// but manually toggling the wifi radio off/on via the GUI (an actual radio/firmware
// reset, deeper than restarting the daemon on top of it) did. Nobody is at the Pi to
// do that by hand, so: on total failure, power-cycle the radio, restart NetworkManager
// for good measure, and give the whole flow one more try before actually giving up.
async function restartNetworkManagerAndWait() {
  console.warn(
    `[WiFi] connect failed — power-cycling wifi radio + restarting NetworkManager, retrying once`
  );
  await runNmcli("radio wifi off");
  await sleep(3000);
  await runNmcli("radio wifi on");
  await sleep(2000);
  await runShell("sudo -n systemctl restart NetworkManager");
  await sleep(5000);
}

async function connectWifi(ssid, password) {
  try {
    return await attemptConnectWifi(ssid, password);
  } catch (e) {
    console.warn(`[WiFi] first attempt failed: ${e.message || e}`);
    await restartNetworkManagerAndWait();
    return attemptConnectWifi(ssid, password);
  }
}

async function writeFailedMeta(processingPath, stamp, originalMeta, errorMessage) {
  const failedName = `${FAILED_PREFIX}${stamp}.json`;
  const failedPath = path.join(path.dirname(processingPath), failedName);
  const base =
    originalMeta && typeof originalMeta === "object" ? { ...originalMeta } : {};
  delete base.password;
  const payload = {
    ...base,
    version: base.version || 1,
    failedAt: new Date().toISOString(),
    error: errorMessage,
  };
  await fsp.writeFile(failedPath, JSON.stringify(payload, null, 2), "utf8");
  try {
    await fsp.unlink(processingPath);
  } catch (_) {
    // processing file may already be gone after rename attempt
  }
  return failedPath;
}

async function processConnectJob(absDir, fileName) {
  const absPath = path.join(absDir, fileName);
  const stamp = parseConnectStamp(fileName);
  if (!stamp) return;

  let s1 = 0;
  let s2 = 0;
  try {
    s1 = (await fsp.stat(absPath)).size;
  } catch {
    return;
  }
  await sleep(400);
  try {
    s2 = (await fsp.stat(absPath)).size;
  } catch {
    return;
  }
  if (s1 !== s2 || s2 === 0) return;

  const processingPath = path.join(absDir, `${PROCESSING_PREFIX}${stamp}.json`);
  let lockedPath;
  try {
    lockedPath = await safeRename(absPath, processingPath);
  } catch (e) {
    console.warn(`[Lock] rename failed for ${absPath}:`, e.message || e);
    return;
  }

  console.log(`[Detect] ${fileName} -> ${path.basename(lockedPath)}`);

  let meta;
  try {
    meta = await readJobJson(lockedPath);
  } catch (e) {
    console.error(`[Error] invalid JSON in ${lockedPath}:`, e.message || e);
    await writeFailedMeta(lockedPath, stamp, null, e.message || String(e));
    return;
  }

  try {
    const result = await connectWifi(meta.ssid, meta.password);
    const completedPath = path.join(absDir, `${COMPLETED_PREFIX}${stamp}.json`);
    const { password: _pw, ...safeMeta } = meta.rawMeta || {};
    const completedPayload = {
      ...safeMeta,
      version: meta.rawMeta?.version || 1,
      ssid: meta.ssid,
      connectedAt: new Date().toISOString(),
      detail: result.detail,
    };
    await fsp.writeFile(
      completedPath,
      JSON.stringify(completedPayload, null, 2),
      "utf8"
    );
    try {
      await fsp.unlink(lockedPath);
    } catch (_) {}
    console.log(`[Done] Wi-Fi connected: ${meta.ssid} -> ${path.basename(completedPath)}`);
  } catch (e) {
    const message = e.message || String(e);
    console.error(`[Fail] Wi-Fi connect failed for ${meta.ssid}:`, message);
    await writeFailedMeta(lockedPath, stamp, meta.rawMeta, message);
    console.log(`[Fail] wrote ${FAILED_PREFIX}${stamp}.json`);
  }
}

async function pollDir(absDir) {
  if (!watchers.has(absDir)) {
    watchers.set(absDir, { running: true });
    console.log(`[Watch] Start: ${absDir}`);
    // #2: 재시작 등으로 남은 processing_* 를 누락 처리 (평문 비밀번호 잔존 방지)
    await sweepStaleProcessingFiles(absDir);
  }
  const state = watchers.get(absDir);

  while (state.running) {
    try {
      const files = await fsp.readdir(absDir);
      const latest = pickLatestConnectWifiFile(files);
      if (latest) {
        await processConnectJob(absDir, latest);
        // #1: 방금 처리한 최신본보다 오래된 connect_wifi_* 는 누락 처리
        await sweepSupersededConnectFiles(absDir, parseConnectStamp(latest));
      }
    } catch (err) {
      if (err && String(err).includes("ENOENT")) {
        console.warn(`[Watch] Dir gone: ${absDir}`);
        break;
      }
      console.error(`[Watch] Error on ${absDir}:`, err);
    }
    await sleep(POLL_MS_FILES);
  }

  watchers.delete(absDir);
  console.log(`[Watch] Stop: ${absDir}`);
}

async function scanMountsLoop() {
  for (;;) {
    try {
      const entries = await fsp.readdir(GVFS_BASE).catch(() => []);
      const afcMounts = entries
        .filter((e) => e.startsWith(AFC_PREFIX))
        .map((e) => path.join(GVFS_BASE, e));

      for (const m of afcMounts) {
        for (const rel of APP_REL_DIRS) {
          const appDir = path.join(m, rel);
          if (!isDir(appDir) || watchers.has(appDir)) continue;
          try {
            await fsp.access(appDir, fs.constants.R_OK);
          } catch {
            continue;
          }
          pollDir(appDir);
        }
      }
    } catch (err) {
      console.error("[MountScan] error:", err);
    }
    await sleep(POLL_MS_MOUNTS);
  }
}

(async () => {
  console.log(`[Init] GVFS_BASE=${GVFS_BASE}`);
  console.log(`[Init] Watching AFC mounts: ${AFC_PREFIX}* / ${APP_REL_DIRS.join(" | ")}`);
  console.log(`[Init] Pattern: connect_wifi_YYMMDD_HHmm.json`);
  console.log(`[Hint] Run as desktop user (uid=1000) so GVFS paths are visible.`);
  await scanMountsLoop();
})();
