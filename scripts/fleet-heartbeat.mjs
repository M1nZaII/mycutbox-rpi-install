#!/usr/bin/env node
/**
 * Periodically report Pi heartbeat for offline detection.
 * Writes to: fleet/ota/deviceReports/{serial}
 */
import { Firestore, FieldValue } from "@google-cloud/firestore";
import fs from "fs";
import os from "os";

const COLLECTION = process.env.FLEET_OTA_COLLECTION || "fleet";
const DOC_ID = process.env.FLEET_OTA_DOC || "ota";

function fleetEnabled() {
  const v = String(process.env.FLEET_OTA_ENABLED ?? "1").trim().toLowerCase();
  return v !== "0" && v !== "false" && v !== "no";
}

function sanitizeOneLine(s) {
  return String(s ?? "")
    .replace(/[\r\n]+/g, " ")
    .trim();
}

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
      // ignore
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
    // ignore
  }
  try {
    const cpu = fs.readFileSync("/proc/cpuinfo", "utf8");
    const m = cpu.match(/^Serial\s*:\s*(\S+)/m);
    if (m?.[1]) return m[1].replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);
  } catch {
    // ignore
  }
  return "unknown";
}

async function main() {
  if (!fleetEnabled()) return;

  const keyFilename = resolveCredentialsPath();
  if (!keyFilename) {
    process.stderr.write("fleet-heartbeat: Firestore credentials not found\n");
    process.exit(1);
  }

  const db = new Firestore({ keyFilename });
  const serial = sanitizeOneLine(process.env.OTA_SERIAL || getSerial()) || "unknown";
  const hostname = sanitizeOneLine(os.hostname());
  const appliedTag = sanitizeOneLine(process.env.AGENT_IMAGE_TAG || "");

  await db
    .collection(COLLECTION)
    .doc(DOC_ID)
    .collection("deviceReports")
    .doc(serial)
    .set(
      {
        serial,
        hostname,
        heartbeatAt: FieldValue.serverTimestamp(),
        heartbeatTag: appliedTag,
      },
      { merge: true }
    );
}

main().catch((err) => {
  process.stderr.write(`fleet-heartbeat: ${err?.message || err}\n`);
  process.exit(1);
});
