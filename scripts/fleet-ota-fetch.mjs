#!/usr/bin/env node
/**
 * Read fleet OTA config from Firestore and optionally report apply status per device.
 *
 * Global: fleet/ota
 *   desiredAgentTag — GHCR tag. Empty = follow repo AGENT_VERSION (unless pilot override).
 *
 * Pilot (1 Pi sandbox): fleet/ota/pilotOverrides/{serial}
 *   trackBranch — git branch to follow (default "pilot")
 *   desiredAgentTag — always resolved to GHCR tag "pilot" when active
 *   revision, reason — per-device; takes priority over global fleet for that serial only.
 *
 * Reports: fleet/ota/deviceReports/{serial}
 * History:  fleet/ota/otaHistory/{autoId}
 */
import { Firestore, FieldValue } from "@google-cloud/firestore";
import fs from "fs";
import os from "os";

const MODE = process.argv[2] || "read";
const COLLECTION = process.env.FLEET_OTA_COLLECTION || "fleet";
const DOC_ID = process.env.FLEET_OTA_DOC || "ota";
const PILOT_IMAGE_TAG = "pilot";
const DEFAULT_PILOT_BRANCH = "pilot";

function resolveCredentialsPath() {
  const candidates = [
    process.env.GOOGLE_APPLICATION_CREDENTIALS,
    process.env.FLEET_OTA_CREDENTIALS,
    `${process.env.HOME || ""}/.pi/data/mycutbox110.json`,
    `${process.env.HOME || ""}/.pi/mycutbox110.json`,
    "/home/rp3/.pi/data/mycutbox110.json",
    "/home/rp3/.pi/mycutbox110.json",
    // Legacy pre-migration path (devices that haven't run the ~/pi -> ~/.pi migration yet).
    `${process.env.HOME || ""}/pi/data/mycutbox110.json`,
    `${process.env.HOME || ""}/pi/mycutbox110.json`,
    "/home/rp3/pi/data/mycutbox110.json",
    "/home/rp3/pi/mycutbox110.json",
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

function fleetEnabled() {
  const v = (process.env.FLEET_OTA_ENABLED ?? "1").trim().toLowerCase();
  return v !== "0" && v !== "false" && v !== "no";
}

function sanitizeOneLine(s) {
  return String(s ?? "")
    .replace(/[\r\n]+/g, " ")
    .trim();
}

function getSerial() {
  const paths = ["/sys/firmware/devicetree/base/serial-number"];
  for (const p of paths) {
    try {
      const raw = fs.readFileSync(p);
      const s = raw.toString("utf8").replace(/\0/g, "").trim();
      if (s) return s.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);
    } catch {
      /* ignore */
    }
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

function pilotOverrideActive(data) {
  if (!data || typeof data !== "object") return false;
  if (data.active === false) return false;
  const branch = sanitizeOneLine(data.trackBranch);
  if (branch) return true;
  const tag = sanitizeOneLine(data.desiredAgentTag);
  if (tag === PILOT_IMAGE_TAG) return true;
  if (/-pilot/i.test(tag)) return true;
  return data.active === true;
}

function resolvePilotGitBranch(pilot) {
  const branch = sanitizeOneLine(pilot?.trackBranch);
  return branch || DEFAULT_PILOT_BRANCH;
}

async function readFleet(db) {
  const serial = sanitizeOneLine(process.env.OTA_SERIAL || getSerial()) || "unknown";

  const globalSnap = await db.collection(COLLECTION).doc(DOC_ID).get();
  const global = globalSnap.exists ? globalSnap.data() || {} : {};

  const pilotSnap = await db
    .collection(COLLECTION)
    .doc(DOC_ID)
    .collection("pilotOverrides")
    .doc(serial)
    .get();
  const pilot = pilotSnap.exists ? pilotSnap.data() || {} : {};

  const globalTag = sanitizeOneLine(global.desiredAgentTag);
  const globalRevision = Number(global.revision) || 0;
  const globalReason = sanitizeOneLine(global.reason);

  const pilotRevision = Number(pilot.revision) || 0;
  const pilotReason = sanitizeOneLine(pilot.reason);
  const pilotActive = pilotOverrideActive(pilot);
  const pilotBranch = resolvePilotGitBranch(pilot);

  let desiredTag = "";
  // 기본값을 globalRevision으로 — desiredAgentTag가 비어있어도(= "그냥 repo AGENT_VERSION 따라가라"도
  // admin이 저장할 때마다 revision이 올라가는 하나의 지시라서, 여기서 0으로 떨어뜨리면 디바이스가 ack하는
  // appliedRevision과 fleet 문서의 revision이 영영 안 맞아 프론트엔드 상태가 "behind"로 잘못 뜬다.
  let revision = globalRevision;
  let reason = globalReason;
  let tagSource = "AGENT_VERSION";

  if (pilotActive) {
    desiredTag = PILOT_IMAGE_TAG;
    revision = pilotRevision;
    reason = pilotReason;
    tagSource = "fleet/ota/pilot";
  } else if (globalTag) {
    desiredTag = globalTag;
    revision = globalRevision;
    reason = globalReason;
    tagSource = "fleet/ota";
  }

  console.log(`DESIRED_TAG=${desiredTag}`);
  console.log(`REVISION=${revision}`);
  console.log(`REASON=${reason}`);
  console.log(`TAG_SOURCE=${tagSource}`);
  console.log(`PILOT_ACTIVE=${pilotActive ? "1" : "0"}`);
  console.log(`PILOT_BRANCH=${pilotBranch}`);
  console.log(`PILOT_REVISION=${pilotRevision}`);
  console.log(`GLOBAL_TAG=${globalTag}`);
  console.log(`GLOBAL_REVISION=${globalRevision}`);
  console.log(`SERIAL=${serial}`);
}

async function ackFleet(db) {
  const serial = sanitizeOneLine(process.argv[3] || getSerial()) || "unknown";
  const appliedTag = sanitizeOneLine(process.argv[4] || "");
  const appliedRevision = Number(process.argv[5]) || 0;
  const tagSource = sanitizeOneLine(process.argv[6] || "AGENT_VERSION");
  const hostname = sanitizeOneLine(os.hostname());
  const pilotOverride = tagSource === "fleet/ota/pilot";

  await db
    .collection(COLLECTION)
    .doc(DOC_ID)
    .collection("deviceReports")
    .doc(serial)
    .set(
      {
        serial,
        hostname,
        appliedAgentTag: appliedTag,
        appliedRevision,
        tagSource,
        pilotOverride,
        lastAppliedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  console.log("OK");
}

async function recordHistory(db) {
  const serial = sanitizeOneLine(process.env.OTA_HISTORY_SERIAL || getSerial()) || "unknown";
  const hostname = sanitizeOneLine(os.hostname());
  const trigger = sanitizeOneLine(process.env.OTA_HISTORY_TRIGGER || "manual");
  const tagBefore = sanitizeOneLine(process.env.OTA_HISTORY_TAG_BEFORE);
  const tagAfter = sanitizeOneLine(process.env.OTA_HISTORY_TAG_AFTER);
  const tagSource = sanitizeOneLine(process.env.OTA_HISTORY_TAG_SOURCE || "AGENT_VERSION");
  const fleetRevision = Number(process.env.OTA_HISTORY_FLEET_REVISION) || 0;
  const fleetReason = sanitizeOneLine(process.env.OTA_HISTORY_FLEET_REASON);
  const gitHeadBefore = sanitizeOneLine(process.env.OTA_HISTORY_HEAD_BEFORE);
  const gitHeadAfter = sanitizeOneLine(process.env.OTA_HISTORY_HEAD_AFTER);
  const changed = process.env.OTA_HISTORY_CHANGED === "1";
  const success = process.env.OTA_HISTORY_SUCCESS !== "0";
  const pilotOverride = tagSource === "fleet/ota/pilot";

  await db.collection(COLLECTION).doc(DOC_ID).collection("otaHistory").add({
    serial,
    hostname,
    trigger,
    tagBefore,
    tagAfter,
    tagSource,
    pilotOverride,
    fleetRevision,
    ...(fleetReason ? { fleetReason } : {}),
    gitHeadBefore,
    gitHeadAfter,
    changed,
    success,
    recordedAt: FieldValue.serverTimestamp(),
  });
  console.log("OK");
}

async function main() {
  if (!fleetEnabled()) {
    process.stderr.write("Fleet OTA disabled (FLEET_OTA_ENABLED=0)\n");
    process.exit(2);
  }

  const keyFilename = resolveCredentialsPath();
  if (!keyFilename) {
    process.stderr.write("Firestore credentials not found\n");
    process.exit(1);
  }

  const db = new Firestore({ keyFilename });

  if (MODE === "read") {
    await readFleet(db);
    return;
  }
  if (MODE === "ack") {
    await ackFleet(db);
    return;
  }
  if (MODE === "history") {
    await recordHistory(db);
    return;
  }

  process.stderr.write(`Unknown mode: ${MODE}\n`);
  process.exit(1);
}

main().catch((err) => {
  process.stderr.write(`${err?.message || err}\n`);
  process.exit(1);
});
