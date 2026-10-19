#!/usr/bin/env node
/**
 * Firestore snapshot listeners:
 *   - fleet/ota (global)
 *   - fleet/ota/pilotOverrides/{this Pi serial} (pilot sandbox — overrides global for this device only)
 *
 * Pilot override wins when active (git branch pilot + GHCR :pilot). Fallback: mycutbox-ota-fleet.timer (60m poll).
 */
import { Firestore } from "@google-cloud/firestore";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const COLLECTION = process.env.FLEET_OTA_COLLECTION || "fleet";
const DOC_ID = process.env.FLEET_OTA_DOC || "ota";
const PROJECT_DIR = process.env.PROJECT_DIR || path.join(os.homedir(), ".pi");
const AGENT_DIR = process.env.AGENT_DIR || path.join(PROJECT_DIR, "agent");
const OTA_BIN = process.env.OTA_BIN || "/usr/local/bin/mycutbox-ota-update";
const STATE_DIR = process.env.OTA_STATE_DIR || path.join(PROJECT_DIR, ".ota-state");
const REVISION_FILE = path.join(STATE_DIR, "fleet-revision");
const ENV_FILE = process.env.ENV_FILE || path.join(PROJECT_DIR, ".env");
const DEBOUNCE_MS = Math.max(3000, Number(process.env.FLEET_OTA_WATCH_DEBOUNCE_MS || 5000) || 5000);
const PILOT_IMAGE_TAG = "pilot";
const DEFAULT_PILOT_BRANCH = "pilot";

function fleetWatchEnabled() {
  const v = (process.env.FLEET_OTA_WATCH_ENABLED ?? "1").trim().toLowerCase();
  return v !== "0" && v !== "false" && v !== "no";
}

function resolveCredentialsPath() {
  const candidates = [
    process.env.GOOGLE_APPLICATION_CREDENTIALS,
    process.env.FLEET_OTA_CREDENTIALS,
    path.join(PROJECT_DIR, "data", "mycutbox110.json"),
    path.join(PROJECT_DIR, "mycutbox110.json"),
  ].filter(Boolean);
  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) return p;
    } catch {
      /* ignore */
    }
  }
  return "";
}

function getSerial() {
  try {
    const raw = fs.readFileSync("/sys/firmware/devicetree/base/serial-number");
    const s = raw.toString("utf8").replace(/\0/g, "").trim();
    if (s) return s.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);
  } catch {
    /* ignore */
  }
  try {
    const cpu = fs.readFileSync("/proc/cpuinfo", "utf8");
    const m = cpu.match(/^Serial\s*:\s*(\S+)/m);
    if (m?.[1]) return m[1].replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);
  } catch {
    /* ignore */
  }
  return "unknown";
}

const SERIAL = getSerial();

function readLocalAgentTag() {
  try {
    const raw = fs.readFileSync(ENV_FILE, "utf8");
    const m = raw.match(/^AGENT_IMAGE_TAG=(.*)$/m);
    return (m?.[1] || "").trim().replace(/\r/g, "");
  } catch {
    return "";
  }
}

function readStoredFleetRevision() {
  try {
    return String(Number(fs.readFileSync(REVISION_FILE, "utf8").trim()) || 0);
  } catch {
    return "0";
  }
}

function readRepoAgentTag() {
  try {
    return fs.readFileSync(path.join(AGENT_DIR, "AGENT_VERSION"), "utf8").trim();
  } catch {
    return "";
  }
}

function pilotOverrideActive(data) {
  if (!data || typeof data !== "object") return false;
  if (data.active === false) return false;
  const branch = String(data.trackBranch || "").trim();
  if (branch) return true;
  const tag = String(data.desiredAgentTag || "").trim();
  if (tag === PILOT_IMAGE_TAG) return true;
  if (/-pilot/i.test(tag)) return true;
  return data.active === true;
}

function buildEffectiveState(globalData, pilotData) {
  const pilot = pilotData || {};
  if (pilotOverrideActive(pilot)) {
    return {
      source: "pilot",
      revision: Number(pilot.revision) || 0,
      desiredAgentTag: PILOT_IMAGE_TAG,
    };
  }
  const global = globalData || {};
  const globalTag = String(global.desiredAgentTag || "").trim();
  if (globalTag) {
    return {
      source: "global",
      revision: Number(global.revision) || 0,
      desiredAgentTag: globalTag,
    };
  }
  return {
    source: "repo",
    revision: 0,
    desiredAgentTag: readRepoAgentTag(),
  };
}

function effectiveKey(state) {
  return `${state.source}:${state.revision}\t${state.desiredAgentTag}`;
}

function shouldTriggerOta(state) {
  const desired = (state.desiredAgentTag || "").trim();
  const localTag = readLocalAgentTag();
  const storedRev = readStoredFleetRevision();

  if (!desired) return false;
  if (localTag !== desired) return true;
  if (String(state.revision) !== storedRev) return true;
  return false;
}

let globalData = null;
let pilotData = null;
let otaRunning = false;
let debounceTimer = null;
let lastHandledKey = "";

function scheduleOta(reason) {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    runOta(reason);
  }, DEBOUNCE_MS);
}

function runOta(reason) {
  if (otaRunning) {
    process.stderr.write(`[fleet-watch] OTA already running; skip (${reason})\n`);
    return;
  }
  otaRunning = true;
  process.stderr.write(`[fleet-watch] Starting OTA: ${reason}\n`);
  const child = spawn(OTA_BIN, ["--fleet"], {
    stdio: "inherit",
    env: process.env,
  });
  child.on("exit", (code) => {
    otaRunning = false;
    process.stderr.write(`[fleet-watch] OTA exited code=${code ?? "?"}\n`);
  });
  child.on("error", (err) => {
    otaRunning = false;
    process.stderr.write(`[fleet-watch] OTA spawn error: ${err.message}\n`);
  });
}

function reevaluate(source) {
  const state = buildEffectiveState(globalData, pilotData);
  const key = effectiveKey(state);

  if (key === lastHandledKey && source === "snapshot") {
    return;
  }

  if (!shouldTriggerOta(state)) {
    lastHandledKey = key;
    process.stderr.write(
      `[fleet-watch] In sync (${state.source} rev=${state.revision}, tag=${readLocalAgentTag()}); listening\n`
    );
    return;
  }

  lastHandledKey = key;
  scheduleOta(`fleet changed source=${state.source} rev=${state.revision} trigger=${source}`);
}

function main() {
  if (!fleetWatchEnabled()) {
    process.stderr.write("[fleet-watch] FLEET_OTA_WATCH_ENABLED=0; exit\n");
    process.exit(0);
  }

  const keyFilename = resolveCredentialsPath();
  if (!keyFilename) {
    process.stderr.write("[fleet-watch] Firestore credentials not found\n");
    process.exit(1);
  }

  const db = new Firestore({ keyFilename });
  const globalRef = db.collection(COLLECTION).doc(DOC_ID);
  const pilotRef = globalRef.collection("pilotOverrides").doc(SERIAL);

  process.stderr.write(
    `[fleet-watch] Listening fleet/ota + pilotOverrides/${SERIAL} (snapshot)\n`
  );

  globalRef.onSnapshot(
    (snap) => {
      globalData = snap.exists ? snap.data() : {};
      reevaluate("global");
    },
    (err) => {
      process.stderr.write(`[fleet-watch] Global snapshot error: ${err.message}\n`);
    }
  );

  pilotRef.onSnapshot(
    (snap) => {
      pilotData = snap.exists ? snap.data() : {};
      reevaluate("pilot");
    },
    (err) => {
      process.stderr.write(`[fleet-watch] Pilot snapshot error: ${err.message}\n`);
    }
  );
}

main();
