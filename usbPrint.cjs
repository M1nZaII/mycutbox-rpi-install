#!/usr/bin/env node

/**
 * version 4-------------------------------------
 * MyCutBox iPad USB Auto-Print Watcher (CommonJS)
 * - Scans GVFS AFC mounts: /run/user/1000/gvfs/afc:host=<UDID>,port=*
 * - Watches: com.mycutbox/MyCutBox 또는 com.mycutbox.kiosk/MyCutBox
 * - Detects new files named:
 *      printThis_{copies}_{docId}_{indices}[ _gray|_bw|_mono ]?.png
 *   e.g., printThis_3_eoYkTjAA3VRZ0aJxbQ7Q_2,3,4,5.png
 *         printThis_3_eoYkTjAA3VRZ0aJxbQ7Q_2,3,4,5_gray.png  (grayscale)
 * - Processing flow:
 *   1) Immediately rename to processing_* (atomic lock)
 *   2) Compose 4 selected JPEGs under the frame PNG and print via CUPS
 *      - If *_gray is present, the selected photos are converted to grayscale
 *   3) On success -> rename to completed_*
 *      On failure -> rename to failed_*
 * - Restart-safe: only files starting with ^printThis_ are picked up
 *
 * ── [v4] LUT(계정 색보정) 오프라인 적용 ─────────────────────────────
 * USB 프린트는 iPad ↔ Pi 직결(오프라인) 경로라 Firestore/네트워크에 의존할 수 없다.
 * 따라서 LUT PNG와 LUT 파라미터를 "로컬에서" 확보해 합성 직전 사진에 적용한다.
 * LUT 채널 규약: cube-to-lut-png.mjs / lutWeb.ts / 앱 Skia 셰이더와 동일하게
 *   Blue = slice(tile, 좌→우), Red = 타일 내 X, Green = 타일 내 Y.
 *
 * LUT 소스 우선순위 (먼저 찾는 것 사용, 없으면 v3와 동일하게 LUT 미적용):
 *   1) 사이드카 JSON(.json)의 lut 정보:
 *        lutPresetId | lutId | selectedLutId
 *        lutPresetUrl | lutUrl | selectedLutUrl
 *        lutStrength (0~1, 기본 1)
 *        lutFileName | lutFile  (USB로 함께 전달된 LUT PNG 파일명/경로)
 *        또는 중첩 객체 lut / accountLut: { id, url, strength, fileName }
 *   2) USB로 함께 전달된 LUT PNG (오프라인 권장):
 *        - 사이드카의 lutFileName/lutFile (대상 디렉터리 기준 상대/절대경로)
 *        - 관례 파일명: {docId}_lut.png, lut_{presetId}.png
 *   3) Pi 로컬 LUT 캐시: {LUT_CACHE_DIR}/{presetId}.png (온라인일 때 미리 받아둔 것)
 *   4) (온라인일 때만) lutPresetUrl 다운로드 → 로컬 캐시에 저장 후 사용
 *
 * grayscale 와 함께 오면: LUT 적용 후 grayscale 변환(흑백이 최종 스타일).
 */

const fs = require("fs");
const fsp = fs.promises;
const os = require("os");
const path = require("path");
const http = require("http");
const https = require("https");
const { exec: execCb } = require("child_process");
const { promisify } = require("util");
const sharp = require("sharp");

const exec = promisify(execCb);

// ====== CONFIG ======
const GVFS_BASE = "/run/user/1000/gvfs";
const AFC_PREFIX = "afc:host="; // iOS AFC mount prefix
// iPad 앱 Documents/MyCutBox 상대 경로들
// USB_APP_REL_DIR: 쉼표로 여러 개 지정 가능 (마운트에 있는 경로만 감시)
// 기본: 정식앱(com.mycutbox) + 키오스크(com.mycutbox.kiosk)
const APP_REL_DIRS = (
  process.env.USB_APP_REL_DIR ||
  "com.mycutbox/MyCutBox,com.mycutbox.kiosk/MyCutBox"
  //org.reactjs.native.example.MyCutBox-Dev
)
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const PRINTER_NAME = "RX1";
const POLL_MS_MOUNTS = 4000;      // polling interval for new AFC mounts
const POLL_MS_FILES  = 2000;      // polling interval for files in target dir
const SEEN_TTL_MS    = 5 * 60 * 1000; // TTL to avoid reprocessing same file
/** CUPS completed 후 실제 용지 출력까지 대기 (print-v25.mjs 와 동일) */
const POST_CUPS_COMPLETE_DELAY_MS = Math.max(
  0,
  Number(process.env.USB_POST_CUPS_COMPLETE_DELAY_MS || 16000) || 16000
);
const CUPS_WAIT_TIMEOUT_MS = Math.max(
  30000,
  Number(process.env.USB_CUPS_WAIT_TIMEOUT_MS || 300000) || 300000
);

// ====== DEBUG (이 파일에서만 변경 — 환경변수 사용 안 함) ======
// USB_PRINT_DEBUG = true  → lp 인화 스킵, ~/Desktop/usbprint-debug 에 LUT·합성본 저장
// USB_PRINT_DEBUG = false → 정상 USB 인화 (운영 기본값)
const USB_PRINT_DEBUG = false;
const USB_DEBUG_BASE_DIR = path.join(os.homedir(), "Desktop", "usbprint-debug");

// print-v25.mjs 와 동일 JPEG 옵션 (mozjpeg + 4:4:4 — LUT 전후 색 일관성)
const PRINT_JPEG_OPTIONS = Object.freeze({
  quality: 94,
  mozjpeg: true,
  chromaSubsampling: "4:4:4",
});

try { sharp.cache(false); } catch (_) {}
try { sharp.concurrency(2); } catch (_) {}

// ====== LUT CONFIG ======
// 온라인일 때 미리 받아둔(혹은 USB로 동기화한) LUT PNG들이 모이는 로컬 캐시 디렉터리.
const LUT_CACHE_DIR = (process.env.USB_LUT_CACHE_DIR || path.join(os.homedir(), ".cache", "mycutbox", "luts")).trim();
// LUT PNG 온라인 다운로드 허용 여부(오프라인 환경에서는 false로 둬도 됨; 기본 허용, 실패해도 무시).
const LUT_ALLOW_DOWNLOAD = String(process.env.USB_LUT_ALLOW_DOWNLOAD ?? "1") !== "0";
const LUT_DOWNLOAD_TIMEOUT_MS = Math.max(3000, Number(process.env.USB_LUT_DOWNLOAD_TIMEOUT_MS || 20000) || 20000);
// LUT 적용 후 슬롯 사진 JPEG 품질(합성 전 단계라 약간 높게).
const LUT_JPEG_QUALITY = Math.max(1, Math.min(100, Number(process.env.USB_LUT_JPEG_QUALITY || 94) || 94));

try { fs.mkdirSync(LUT_CACHE_DIR, { recursive: true }); } catch (_) {}

// ====== ICC CONFIG (print-v25.mjs 와 동일 — JPEG→PNM 시 sRGB→프린터 ICC) ======
const ICC_CACHE_DIR = path.join(os.homedir(), ".cache", "mycutbox", "icc");
const ICC_INPUT_PROFILE_PATH = (
  process.env.ICC_INPUT_PROFILE_PATH || "/usr/share/color/icc/colord/sRGB.icc"
).trim();
const USB_PRINTER_ICC_PATH = (process.env.USB_PRINTER_ICC_PATH || "").trim();
const IMAGE_MAGICK_BIN = (process.env.IMAGE_MAGICK_BIN || "").trim();
try { fs.mkdirSync(ICC_CACHE_DIR, { recursive: true }); } catch (_) {}

let imageMagickCommandCache;

// LUT 데이터(파일 경로 → raw RGB + layout) 메모리 캐시. 한 번 디코드하면 재사용.
const lutDataCache = new Map(); // localPath -> { data, width, height, lutSize, tilesPerRow, tileRows }

// Composition parameters (assumes frame is 1280x1920)
const CANVAS_W = 1280;
const CANVAS_H = 1920;
const SLOT_W   = 463;
const SLOT_H   = 689;
const OFFSET_X = 165;
const OFFSET_Y = 78;
const GAP      = 22;
const SLOT_OVERFLOW_PX = 4;
const HALF_WIDTH = 640;
const HALF_WIDTH_RATIO = HALF_WIDTH / CANVAS_H;
const HALF_WIDTH_RATIO_TOLERANCE = 0.04;
const HALF_WIDTH_TWO_UP_OUTPUT_WIDTH = Math.max(
  1,
  Math.round(Number(process.env.HALF_WIDTH_TWO_UP_OUTPUT_WIDTH || 1248) || 1248)
);
const HALF_WIDTH_TWO_UP_LEFT_X = Math.round(
  Number(process.env.HALF_WIDTH_TWO_UP_LEFT_X || 25) || 25
);
const HALF_WIDTH_TWO_UP_RIGHT_X = Math.round(
  Number(process.env.HALF_WIDTH_TWO_UP_RIGHT_X || 628) || 628
);
const HALF_WIDTH_TWO_UP_LEFT_IMAGE_WIDTH = Math.max(
  1,
  Math.round(Number(process.env.HALF_WIDTH_TWO_UP_LEFT_IMAGE_WIDTH || 608) || 608)
);
const HALF_WIDTH_TWO_UP_RIGHT_IMAGE_WIDTH = Math.max(
  1,
  Math.round(Number(process.env.HALF_WIDTH_TWO_UP_RIGHT_IMAGE_WIDTH || 604) || 604)
);
const HALF_WIDTH_TWO_UP_IMAGE_HEIGHT = Math.max(
  1,
  Math.round(Number(process.env.HALF_WIDTH_TWO_UP_IMAGE_HEIGHT || 1888) || 1888)
);
const HALF_WIDTH_TWO_UP_IMAGE_TOP = Math.round(
  Number(process.env.HALF_WIDTH_TWO_UP_IMAGE_TOP || 8) || 8
);

// 2x2 placement (top-left, top-right, bottom-left, bottom-right)
const POSITIONS = [
  { left: OFFSET_X,                          top: OFFSET_Y },
  { left: CANVAS_W - OFFSET_X - SLOT_W,      top: OFFSET_Y },
  { left: OFFSET_X,                          top: OFFSET_Y + SLOT_H + GAP },
  { left: CANVAS_W - OFFSET_X - SLOT_W,      top: OFFSET_Y + SLOT_H + GAP },
];

// ====== STATE ======
const watchers = new Map(); // absDir -> { running, lastScan }
const seen = new Map();     // abs file path -> timestamp
const sidecarMissingWarned = new Set(); // json path -> warned once

// Periodically purge seen cache
setInterval(() => {
  const now = Date.now();
  for (const [k, t] of seen.entries()) {
    if (now - t > SEEN_TTL_MS) seen.delete(k);
  }
}, 30000);

// ====== UTILS ======
function isDir(p) {
  try { return fs.statSync(p).isDirectory(); }
  catch { return false; }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function formatDebugDatePart(d = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function formatDebugTimePart(d = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
}

async function createDebugSessionDir(docId) {
  const now = new Date();
  // print.mjs의 COMPOSITE_DEBUG_MODE와 동일하게 날짜 폴더로 나눠서 시간순 정리되게 함.
  const sessionDir = path.join(
    USB_DEBUG_BASE_DIR,
    formatDebugDatePart(now),
    `${formatDebugTimePart(now)}_${safeCacheNamePart(docId)}`
  );
  await fsp.mkdir(sessionDir, { recursive: true });
  return sessionDir;
}

async function copyToDebug(sessionDir, relName, srcPath) {
  if (!sessionDir || !srcPath) return;
  try {
    if (!(await fileExists(srcPath))) return;
    const dest = path.join(sessionDir, relName);
    await fsp.mkdir(path.dirname(dest), { recursive: true });
    await fsp.copyFile(srcPath, dest);
  } catch (e) {
    console.warn(`[Debug] copy failed ${relName}:`, e.message || e);
  }
}

async function writeDebugJson(sessionDir, relName, data) {
  if (!sessionDir) return;
  try {
    const dest = path.join(sessionDir, relName);
    await fsp.mkdir(path.dirname(dest), { recursive: true });
    await fsp.writeFile(dest, JSON.stringify(data, null, 2), "utf8");
  } catch (e) {
    console.warn(`[Debug] write json failed ${relName}:`, e.message || e);
  }
}

/** Parse "printThis_{copies}_{docId}_{indices}(_gray|_bw|_mono)? .png"
 *  NOTE: indices may be 0-based (0..5) OR 1-based (1..6). We normalize later.
 *  Grayscale flag if an optional suffix token is present (gray/grey/bw/mono).
 */
function parsePrintThis(filename) {
  const m = /^printThis_(\d+)_([^_]+)_([0-9,]+|all)(?:_(gray|grey|bw|mono))?\.png$/i.exec(filename);
  if (!m) return null;
  const copies = parseInt(m[1], 10);
  const docId = m[2];
  const indices = m[3].toLowerCase() === "all"
    ? [0, 1, 2, 3]
    : m[3]
      .split(",")
      .map((s) => parseInt(s, 10))
      .filter(Number.isFinite);
  const grayscale = !!m[4]; // optional suffix present
  return { copies, docId, indices, grayscale };
}

function isHalfWidthLayoutSize(width, height) {
  const w = Number(width);
  const h = Number(height);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return false;
  return (
    w <= 700 &&
    h >= 1800 &&
    Math.abs(w / h - HALF_WIDTH_RATIO) <= HALF_WIDTH_RATIO_TOLERANCE
  );
}

function normalizeUsbPrintMeta(raw, fallback) {
  if (!raw || typeof raw !== "object") return null;
  const selectedIndices = Array.isArray(raw.selectedIndices) && raw.selectedIndices.length > 0
    ? raw.selectedIndices
    : fallback.indices;
  const canvas = raw.canvas || {};
  const canvasW = Number(canvas.width || raw.refWidth || raw.canvasWidth);
  const canvasH = Number(canvas.height || raw.refHeight || raw.canvasHeight);
  const rawSlots = Array.isArray(raw.slots) ? raw.slots : [];
  const slots = rawSlots
    .map((slot, index) => ({
      index: Number.isFinite(Number(slot?.index)) ? Number(slot.index) : index,
      left: Number(slot?.left) || 0,
      top: Number(slot?.top) || 0,
      width: Number(slot?.width) || 0,
      height: Number(slot?.height) || 0,
    }))
    .filter((slot) => slot.width > 0 && slot.height > 0)
    .sort((a, b) => a.index - b.index);
  if (!Number.isFinite(canvasW) || !Number.isFinite(canvasH) || canvasW <= 0 || canvasH <= 0 || slots.length === 0) {
    return null;
  }
  return {
    ...fallback,
    ...raw,
    copies: Number(raw.copies) > 0 ? Math.round(Number(raw.copies)) : fallback.copies,
    docId: raw.docId || fallback.docId,
    selectedIndices,
    indices: selectedIndices,
    grayscale: Boolean(raw.grayscale ?? fallback.grayscale),
    canvasW: Math.round(canvasW),
    canvasH: Math.round(canvasH),
    slots,
    isHalfWidthLayout: isHalfWidthLayoutSize(canvasW, canvasH),
  };
}

async function readUsbPrintSidecar(absPath, fallback) {
  const jsonPath = absPath.replace(/\.png$/i, ".json");
  if (!(await fileExists(jsonPath))) {
    if (!sidecarMissingWarned.has(jsonPath)) {
      sidecarMissingWarned.add(jsonPath);
      console.warn(
        `[Meta] No sidecar JSON (${path.basename(jsonPath)}) — default 4x6 layout, no LUT from sidecar`
      );
    }
    return null;
  }
  try {
    const parsed = JSON.parse(await fsp.readFile(jsonPath, "utf8"));
    const meta = normalizeUsbPrintMeta(parsed, fallback);
    if (meta) {
      const lutHint =
        meta.lutPresetId ||
        meta.lutFileName ||
        meta.accountLut?.id ||
        meta.accountLut?.fileName ||
        "-";
      console.log(
        `[Meta] ${path.basename(jsonPath)} layout=${meta.layoutId || "-"} canvas=${meta.canvasW}x${meta.canvasH} slots=${meta.slots.length} half=${meta.isHalfWidthLayout} lut=${lutHint}`
      );
      return meta;
    }
    // 레이아웃 정규화는 실패했지만 LUT 정보가 있으면 LUT만이라도 흘려보낸다(슬롯은 기본값 폴백).
    if (parsed && (parsed.lutPresetId || parsed.lutPresetUrl || parsed.lutFileName || parsed.lut || parsed.accountLut)) {
      console.log(`[Meta] ${path.basename(jsonPath)} layout invalid; carrying LUT info only`);
      return {
        ...fallback,
        lutPresetId: parsed.lutPresetId,
        lutPresetUrl: parsed.lutPresetUrl,
        lutStrength: parsed.lutStrength,
        lutStrengths: parsed.lutStrengths,
        lutFileName: parsed.lutFileName,
        lut: parsed.lut,
        accountLut: parsed.accountLut,
      };
    }
    console.warn(
      `[Meta] ${path.basename(jsonPath)} present but canvas/slots invalid — default 4x6 layout`
    );
    return null;
  } catch (e) {
    console.warn(`[Meta] Failed to read ${jsonPath}:`, e.message || e);
    return null;
  }
}

async function fileExists(p) {
  try { await fsp.access(p, fs.constants.R_OK); return true; }
  catch { return false; }
}

/** Build a path with a prefix inserted before the basename */
function prefixedPath(p, prefix) {
  const dir = path.dirname(p);
  const base = path.basename(p);
  return path.join(dir, `${prefix}${base}`);
}

/** Safely rename, avoiding collisions by appending a timestamp if necessary */
async function safeRename(src, dest) {
  if (await fileExists(dest)) {
    const dir = path.dirname(dest);
    const base = path.basename(dest);
    const alt = path.join(dir, `${Date.now()}_${base}`);
    await fsp.rename(src, alt);
    return alt;
  } else {
    await fsp.rename(src, dest);
    return dest;
  }
}

/** Immediately lock a printThis_* file by renaming to processing_* */
async function markProcessing(absPath) {
  const processingPath = prefixedPath(absPath, "processing_");
  return await safeRename(absPath, processingPath);
}

/** Mark a processing_* file as completed_* */
async function markCompleted(processingPath) {
  const dir = path.dirname(processingPath);
  const base = path.basename(processingPath);
  const completed = base.startsWith("processing_")
    ? base.replace(/^processing_/, "completed_")
    : `completed_${base}`;
  const dest = path.join(dir, completed);
  return await safeRename(processingPath, dest);
}

/** Mark a processing_* file as failed_* */
async function markFailed(processingPath) {
  const dir = path.dirname(processingPath);
  const base = path.basename(processingPath);
  const failed = base.startsWith("processing_")
    ? base.replace(/^processing_/, "failed_")
    : `failed_${base}`;
  const dest = path.join(dir, failed);
  return await safeRename(processingPath, dest);
}

/** Normalize indices to 1-based (expects 4 values).
 * Accepts either 0..5 or 1..6 and returns 1..6.
 */
function normalizeToOneBased(indices) {
  if (!Array.isArray(indices) || indices.length === 0) return indices;
  const min = Math.min(...indices);
  const max = Math.max(...indices);
  if (min >= 0 && max <= 5) return indices.map((i) => i + 1); // 0-based -> 1-based
  if (min >= 1 && max <= 6) return indices;                   // already 1-based
  return indices.map((i) => i + 1);                            // fallback
}

/**
 * Resolve path for original JPEG given docId and 1-based index.
 * Tries {docId}_pictures{idx}.jpg|jpeg in the same directory.
 */
async function resolvePicturePath(dir, docId, idxOneBased) {
  // 고객이 그 슬롯에서 AI 배경합성을 선택했으면 앱이 원본과 별도로
  // {docId}_ai_pictures{N} 파일을 함께 저장해둔다 — 있으면 그걸 우선 쓰고,
  // 없으면(AI 미선택/미지원) 원본으로 폴백한다. 재인화 때도 동일하게 적용되어
  // 별도 메타데이터 없이 처음 선택한 버전이 그대로 유지된다.
  const aiCands = [
    path.join(dir, `${docId}_ai_pictures${idxOneBased}.jpg`),
    path.join(dir, `${docId}_ai_pictures${idxOneBased}.jpeg`),
    path.join(dir, `${docId}_ai_Pictures${idxOneBased}.jpg`),
    path.join(dir, `${docId}_ai_Pictures${idxOneBased}.jpeg`),
  ];
  for (const p of aiCands) {
    if (await fileExists(p)) return p;
  }

  const cands = [
    path.join(dir, `${docId}_pictures${idxOneBased}.jpg`),
    path.join(dir, `${docId}_pictures${idxOneBased}.jpeg`),
    path.join(dir, `${docId}_Pictures${idxOneBased}.jpg`),
    path.join(dir, `${docId}_Pictures${idxOneBased}.jpeg`),
  ];
  for (const p of cands) {
    if (await fileExists(p)) return p;
  }
  // Fallback: search directory (AI 파일은 이미 위에서 확인 끝났으므로 원본만 대상)
  const files = await fsp.readdir(dir);
  const found = files.find((f) =>
    f.includes(docId) &&
    f.includes(`pictures${idxOneBased}`) &&
    !f.toLowerCase().includes(`ai_pictures${idxOneBased}`) &&
    (f.toLowerCase().endsWith(".jpg") || f.toLowerCase().endsWith(".jpeg"))
  );
  return found ? path.join(dir, found) : null;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function resolveImageMagickCommand() {
  if (imageMagickCommandCache !== undefined) return imageMagickCommandCache;
  const candidates = IMAGE_MAGICK_BIN ? [IMAGE_MAGICK_BIN] : ["magick", "convert"];
  for (const candidate of candidates) {
    try {
      await exec(`command -v ${shellQuote(candidate)}`);
      imageMagickCommandCache = candidate;
      return imageMagickCommandCache;
    } catch (_) {
      // try next
    }
  }
  imageMagickCommandCache = "";
  return imageMagickCommandCache;
}

async function resolveUsbPrinterIccProfilePath() {
  if (USB_PRINTER_ICC_PATH && fs.existsSync(USB_PRINTER_ICC_PATH)) {
    return USB_PRINTER_ICC_PATH;
  }
  try {
    const files = await fsp.readdir(ICC_CACHE_DIR);
    const iccs = files
      .filter((f) => /\.(icc|icm)$/i.test(f))
      .map((f) => path.join(ICC_CACHE_DIR, f));
    if (iccs.length === 0) return null;
    if (iccs.length === 1) return iccs[0];
    const stats = await Promise.all(
      iccs.map(async (p) => ({ p, m: (await fsp.stat(p)).mtimeMs }))
    );
    stats.sort((a, b) => b.m - a.m);
    return stats[0].p;
  } catch {
    return null;
  }
}

async function convertJpegToPnmWithDjpeg(jpegPath, outPnm, grayscale = false) {
  const fmt = grayscale ? "-grayscale" : "-pnm";
  await exec(`djpeg ${fmt} ${shellQuote(jpegPath)} > ${shellQuote(outPnm)}`);
}

async function convertJpegToPnmForPrint(docId, inputJpegPath, pnmPath, label, grayscale = false) {
  try {
    const printerIcc = await resolveUsbPrinterIccProfilePath();
    if (!printerIcc) {
      console.log(`[ICC] ${docId} skipped: no printer ICC (${label})`);
      await convertJpegToPnmWithDjpeg(inputJpegPath, pnmPath, grayscale);
      return;
    }

    const imageMagickCmd = await resolveImageMagickCommand();
    if (!imageMagickCmd) {
      throw new Error("ImageMagick command not found (magick/convert)");
    }

    const sourceProfileArgs =
      ICC_INPUT_PROFILE_PATH && fs.existsSync(ICC_INPUT_PROFILE_PATH)
        ? ` -profile ${shellQuote(ICC_INPUT_PROFILE_PATH)}`
        : "";
    if (!sourceProfileArgs && ICC_INPUT_PROFILE_PATH) {
      console.log(`[ICC] ${docId} source profile not found: ${ICC_INPUT_PROFILE_PATH}`);
    }

    const profileArgs = `${sourceProfileArgs} -profile ${shellQuote(printerIcc)}`;
    const convertCmd =
      `${shellQuote(imageMagickCmd)} ${shellQuote(inputJpegPath)} -auto-orient${profileArgs} ` +
      `${shellQuote(`PNM:${pnmPath}`)}`;

    console.log(`[ICC] ${docId} apply via ImageMagick: ${path.basename(printerIcc)} (${label})`);
    await exec(convertCmd);
  } catch (e) {
    console.warn(`[ICC] ${docId} fallback djpeg without ICC (${label}):`, e.message || e);
    await convertJpegToPnmWithDjpeg(inputJpegPath, pnmPath, grayscale);
  }
}

async function waitForCupsJobComplete(jobTag, timeoutMs = CUPS_WAIT_TIMEOUT_MS) {
  const pollMs = 5000;
  const start = Date.now();
  console.log(
    `[CUPS Wait] ${jobTag} waiting (timeout ${Math.round(timeoutMs / 1000)}s)...`
  );
  while (Date.now() - start < timeoutMs) {
    try {
      const notCompletedCmd =
        `env LANG=C lpstat -W not-completed -o | awk '{print $1}' | grep -Fx "${jobTag}"`;
      await exec(notCompletedCmd);
      console.log(
        `[CUPS Wait] ${jobTag} still in queue, next check in ${pollMs / 1000}s`
      );
    } catch {
      try {
        const completedCmd =
          `env LANG=C lpstat -W completed -o | awk '{print $1}' | grep -Fx "${jobTag}"`;
        await exec(completedCmd);
        console.log(`[CUPS Wait] ${jobTag} completed`);
        if (POST_CUPS_COMPLETE_DELAY_MS > 0) {
          console.log(
            `[CUPS Wait] ${jobTag} post-delay ${POST_CUPS_COMPLETE_DELAY_MS / 1000}s for paper out`
          );
          await sleep(POST_CUPS_COMPLETE_DELAY_MS);
        }
        return true;
      } catch {
        console.warn(
          `[CUPS Wait] ${jobTag} not in not-completed or completed (canceled/expired?)`
        );
        return false;
      }
    }
    await sleep(pollMs);
  }
  console.warn(`[CUPS Wait] ${jobTag} timeout after ${timeoutMs}ms`);
  return false;
}

function parseLpJobTag(lpStdout) {
  const m = String(lpStdout || "").match(/request id is\s+(.+?)-(\d+)(?:\s|\(|$)/i);
  if (!m) return null;
  return `${m[1].trim()}-${m[2]}`;
}

// ====== LUT helpers (offline strip-LUT, Blue=slice / Red=X / Green=Y) ======

function clampNum(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function safeCacheNamePart(value) {
  return (
    String(value || "")
      .trim()
      .replace(/[^a-zA-Z0-9._-]/g, "_")
      .slice(0, 80) || "lut"
  );
}

/** LUT PNG 해상도로 타일 레이아웃 추론 (width=size*size, height=size 형태 등) */
function detectLutLayoutWH(width, height) {
  if (width <= 0 || height <= 0) return null;
  if (width === height * height) {
    return { lutSize: height, tilesPerRow: height, tileRows: 1, width, height };
  }
  if (width === height) {
    const cubeRoot = Math.round(Math.cbrt(width));
    if (cubeRoot > 0 && cubeRoot * cubeRoot * cubeRoot === width) {
      return { lutSize: cubeRoot * cubeRoot, tilesPerRow: cubeRoot, tileRows: cubeRoot, width, height };
    }
  }
  if (width % height === 0) {
    const lutSize = height;
    const tilesPerRow = width / lutSize;
    const tileRows = Math.max(1, Math.ceil(lutSize / tilesPerRow));
    if (tileRows * lutSize === height) {
      return { lutSize, tilesPerRow, tileRows, width, height };
    }
  }
  return null;
}

function getLutChannel(data, width, x, y) {
  const clampedX = clampNum(Math.round(x), 0, width - 1);
  const maxY = Math.floor(data.length / 3 / width) - 1;
  const clampedY = clampNum(Math.round(y), 0, maxY);
  const index = (clampedY * width + clampedX) * 3;
  return [data[index], data[index + 1], data[index + 2]];
}

function sampleBilinearRgb(data, width, height, x, y) {
  const x0 = clampNum(Math.floor(x), 0, width - 1);
  const y0 = clampNum(Math.floor(y), 0, height - 1);
  const x1 = clampNum(x0 + 1, 0, width - 1);
  const y1 = clampNum(y0 + 1, 0, height - 1);
  const tx = clampNum(x - x0, 0, 1);
  const ty = clampNum(y - y0, 0, 1);

  const c00 = getLutChannel(data, width, x0, y0);
  const c10 = getLutChannel(data, width, x1, y0);
  const c01 = getLutChannel(data, width, x0, y1);
  const c11 = getLutChannel(data, width, x1, y1);

  const mixX0 = [
    c00[0] + (c10[0] - c00[0]) * tx,
    c00[1] + (c10[1] - c00[1]) * tx,
    c00[2] + (c10[2] - c00[2]) * tx,
  ];
  const mixX1 = [
    c01[0] + (c11[0] - c01[0]) * tx,
    c01[1] + (c11[1] - c01[1]) * tx,
    c01[2] + (c11[2] - c01[2]) * tx,
  ];
  return [
    mixX0[0] + (mixX1[0] - mixX0[0]) * ty,
    mixX0[1] + (mixX1[1] - mixX0[1]) * ty,
    mixX0[2] + (mixX1[2] - mixX0[2]) * ty,
  ];
}

// LUT PNG 규약: Blue = slice(tile), Red = 타일 내 X, Green = 타일 내 Y
function sampleLutSlice(lut, sliceIndex, redPos, greenPos) {
  const tileX = sliceIndex % lut.tilesPerRow;
  const tileY = Math.min(Math.floor(sliceIndex / lut.tilesPerRow), lut.tileRows - 1);
  const x = tileX * lut.lutSize + redPos;
  const y = tileY * lut.lutSize + greenPos;
  return sampleBilinearRgb(lut.data, lut.width, lut.height, x, y);
}

/** raw RGB(width*height*3) 버퍼에 LUT 적용 → 새 raw 버퍼 반환 */
function applyLutToRawBuffer(srcData, lut, strengthRaw) {
  const dst = Buffer.from(srcData);
  const sizeMinusOne = Math.max(1, lut.lutSize - 1);
  const strength = clampNum(Number(strengthRaw), 0, 1);

  for (let i = 0; i < dst.length; i += 3) {
    const red = dst[i] / 255;
    const green = dst[i + 1] / 255;
    const blue = dst[i + 2] / 255;

    const redPos = red * sizeMinusOne;
    const greenPos = green * sizeMinusOne;
    const slice = blue * sizeMinusOne;
    const slice0 = Math.floor(slice);
    const slice1 = Math.min(slice0 + 1, sizeMinusOne);
    const sliceMix = slice - slice0;

    const lut0 = sampleLutSlice(lut, slice0, redPos, greenPos);
    const lut1 = sampleLutSlice(lut, slice1, redPos, greenPos);
    const mappedRed = lut0[0] + (lut1[0] - lut0[0]) * sliceMix;
    const mappedGreen = lut0[1] + (lut1[1] - lut0[1]) * sliceMix;
    const mappedBlue = lut0[2] + (lut1[2] - lut0[2]) * sliceMix;

    dst[i] = Math.round(dst[i] + (mappedRed - dst[i]) * strength);
    dst[i + 1] = Math.round(dst[i + 1] + (mappedGreen - dst[i + 1]) * strength);
    dst[i + 2] = Math.round(dst[i + 2] + (mappedBlue - dst[i + 2]) * strength);
  }
  return dst;
}

/** LUT가 실제로 색을 바꾸는지 합성 버퍼로 빠르게 검증 (identity/손상 PNG 탐지) */
function measureLutAverageDelta(lut, strengthRaw = 1) {
  const w = 8;
  const h = 8;
  const testBuf = Buffer.alloc(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3;
      testBuf[i] = 40 + x * 20;
      testBuf[i + 1] = 60 + y * 15;
      testBuf[i + 2] = 100 + ((x + y) % 3) * 40;
    }
  }
  const out = applyLutToRawBuffer(testBuf, lut, strengthRaw);
  let sum = 0;
  for (let i = 0; i < testBuf.length; i++) sum += Math.abs(out[i] - testBuf[i]);
  return sum / testBuf.length;
}

/** print-v25.mjs applyLutToJpegPath 와 동일: resize JPEG → raw LUT → JPEG */
async function applyLutToJpegPath(sourcePath, destPath, lut, strengthRaw) {
  const { data: srcData, info } = await sharp(sourcePath)
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const dst = applyLutToRawBuffer(srcData, lut, strengthRaw);
  let deltaSum = 0;
  for (let i = 0; i < srcData.length; i++) deltaSum += Math.abs(dst[i] - srcData[i]);
  await sharp(dst, {
    raw: { width: info.width, height: info.height, channels: 3 },
  })
    .jpeg(PRINT_JPEG_OPTIONS)
    .toFile(destPath);
  return deltaSum / srcData.length;
}

/** LUT PNG 파일을 디코드해 raw RGB + layout 으로 캐시 */
async function loadLutImageData(localPath) {
  if (lutDataCache.has(localPath)) return lutDataCache.get(localPath);
  const { data, info } = await sharp(localPath).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const layout = detectLutLayoutWH(info.width, info.height);
  if (!layout) {
    throw new Error(`Unsupported LUT image layout ${info.width}x${info.height} (${localPath})`);
  }
  const loaded = { data, ...layout };
  lutDataCache.set(localPath, loaded);
  return loaded;
}

function downloadFileHttp(url, dest) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("http://") ? http : https;
    const file = fs.createWriteStream(dest);
    let settled = false;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      try { file.close(); } catch (_) {}
      fs.unlink(dest, () => {});
      reject(err);
    };
    const req = mod.get(url, (res) => {
      if (!res.statusCode || res.statusCode >= 400) {
        fail(new Error(`HTTP ${res.statusCode}`));
        return;
      }
      res.pipe(file);
      file.on("finish", () => {
        if (settled) return;
        settled = true;
        file.close(() => resolve(dest));
      });
    });
    req.on("error", fail);
    req.setTimeout(LUT_DOWNLOAD_TIMEOUT_MS, () => req.destroy(new Error("LUT download timeout")));
  });
}

/** 사이드카 메타에서 LUT 정보 추출 → { id, url, strength, fileName } | null */
function extractLutInfo(meta) {
  if (!meta || typeof meta !== "object") return null;
  const nested = (meta.lut && typeof meta.lut === "object" && meta.lut) ||
    (meta.accountLut && typeof meta.accountLut === "object" && meta.accountLut) ||
    {};
  const pick = (...keys) => {
    for (const k of keys) {
      const v = meta[k] ?? nested[k];
      if (typeof v === "string" && v.trim() !== "") return v.trim();
    }
    return "";
  };
  const id = pick("lutPresetId", "lutId", "selectedLutId", "id");
  const url = pick("lutPresetUrl", "lutUrl", "selectedLutUrl", "url");
  const fileName = pick("lutFileName", "lutFile", "fileName");
  const strengthRaw = meta.lutStrength ?? nested.strength ?? nested.lutStrength;
  let strength = 1;
  if (strengthRaw !== null && strengthRaw !== undefined && strengthRaw !== "") {
    const parsed = Number(strengthRaw);
    if (Number.isFinite(parsed)) strength = clampNum(parsed, 0, 1);
  }

  // 아무 소스도 없으면 LUT 없음
  if (!id && !url && !fileName) return null;
  const idLower = id.toLowerCase();
  if (idLower === "original" || idLower === "none" || idLower === "off") return null;
  const hasPerPhotoStrength =
    Array.isArray(meta.lutStrengths) &&
    meta.lutStrengths.some((s) => Number.isFinite(Number(s)) && Number(s) > 0);
  if (strength <= 0 && !hasPerPhotoStrength) return null;
  return { id, url, strength, fileName };
}

function existsNonEmpty(p) {
  try {
    return !!p && fs.existsSync(p) && fs.statSync(p).size > 0;
  } catch (_) {
    return false;
  }
}

/** USB로 전달된 LUT PNG를 Pi 영속 캐시에 적재. url이 바뀌면 덮어쓴다. */
function getLutMetaPath(pngPath) {
  return pngPath.replace(/\.png$/i, ".meta.json");
}

function readLutCacheMetaFile(metaPath) {
  try {
    if (!fs.existsSync(metaPath)) return null;
    const parsed = JSON.parse(fs.readFileSync(metaPath, "utf8"));
    if (typeof parsed?.url === "string" && parsed.url.trim() !== "") {
      return parsed;
    }
  } catch (_) {}
  return null;
}

function writeLutCacheMetaFile(metaPath, { id, url }) {
  fs.writeFileSync(
    metaPath,
    JSON.stringify({ id: id || "", url: url || "", cachedAt: new Date().toISOString() })
  );
}

function isLutCacheValid(pngPath, expectedUrl) {
  if (!existsNonEmpty(pngPath)) return false;
  if (!expectedUrl) return true;
  const meta = readLutCacheMetaFile(getLutMetaPath(pngPath));
  return meta?.url === expectedUrl;
}

function invalidateLutCacheFile(pngPath) {
  try {
    if (pngPath && fs.existsSync(pngPath)) fs.unlinkSync(pngPath);
    const metaPath = getLutMetaPath(pngPath);
    if (metaPath && fs.existsSync(metaPath)) fs.unlinkSync(metaPath);
  } catch (_) {}
}

function persistLutToCache(srcPath, cachePath, lutInfo = {}) {
  if (!cachePath || !srcPath || srcPath === cachePath) return;
  const { id = "", url = "" } = lutInfo;
  const metaPath = getLutMetaPath(cachePath);
  try {
    if (isLutCacheValid(cachePath, url)) return;
    if (existsNonEmpty(cachePath) && url) invalidateLutCacheFile(cachePath);
    const tmp = `${cachePath}.tmp-${process.pid}-${Date.now()}`;
    fs.copyFileSync(srcPath, tmp);
    fs.renameSync(tmp, cachePath);
    if (url) writeLutCacheMetaFile(metaPath, { id, url });
    console.log(`[LUT] cached -> ${path.basename(cachePath)} (재사용용)`);
  } catch (e) {
    console.warn(`[LUT] cache persist failed: ${e.message || e}`);
  }
}

/** 슬롯(선택 순서)별 LUT 강도. lutStrengths[i] → 없거나 null이면 lutStrength 폴백 */
function resolvePhotoLutStrength(meta, slotIndex, defaultStrength) {
  const strengths = meta?.lutStrengths;
  if (Array.isArray(strengths) && strengths.length > slotIndex) {
    const raw = strengths[slotIndex];
    if (raw !== null && raw !== undefined && raw !== "") {
      const s = Number(raw);
      if (Number.isFinite(s)) return clampNum(s, 0, 1);
    }
  }
  const fallback = Number(meta?.lutStrength ?? defaultStrength);
  return Number.isFinite(fallback) ? clampNum(fallback, 0, 1) : 1;
}

function invalidateLutDataCache(...paths) {
  for (const p of paths) {
    if (p) lutDataCache.delete(p);
  }
}

/**
 * 합성에 사용할 LUT PNG의 로컬 경로를 확보한다.
 * USB 프린트 우선순위: USB 동봉 PNG(iPad가 방금 전달) → Pi 캐시 → 온라인 다운로드.
 */
async function resolveLutForJob(dir, docId, lutInfo) {
  if (!lutInfo) return null;
  const { id, url, strength, fileName } = lutInfo;
  const cachePath = id ? path.join(LUT_CACHE_DIR, `${safeCacheNamePart(id)}.png`) : null;

  // 1) USB로 함께 전달된 LUT PNG (오프라인 USB — iPad 전달본이 최우선)
  const siblingCandidates = [];
  if (fileName) siblingCandidates.push(path.isAbsolute(fileName) ? fileName : path.join(dir, fileName));
  if (id) siblingCandidates.push(path.join(dir, `lut_${safeCacheNamePart(id)}.png`));
  if (docId) siblingCandidates.push(path.join(dir, `${docId}_lut.png`));

  for (const c of siblingCandidates) {
    if (existsNonEmpty(c)) {
      invalidateLutDataCache(c, cachePath);
      if (cachePath) persistLutToCache(c, cachePath, { id, url });
      console.log(`[LUT] source=usb file=${path.basename(c)}`);
      return { localPath: c, strength, source: "usb" };
    }
  }

  // 2) Pi 영속 캐시 — url 일치할 때만 재사용
  if (cachePath && isLutCacheValid(cachePath, url)) {
    console.log(`[LUT] source=cache file=${path.basename(cachePath)}`);
    return { localPath: cachePath, strength, source: "cache" };
  }
  if (cachePath && existsNonEmpty(cachePath) && url) {
    invalidateLutCacheFile(cachePath);
    invalidateLutDataCache(cachePath);
  }

  // 3) (온라인) URL 다운로드 → 캐시에 저장
  const dlPath = await downloadLutToCache({ id, url, strength, fileName });
  if (dlPath) {
    return { localPath: dlPath, strength, source: "download" };
  }

  console.warn(
    `[LUT] no local LUT source found (id=${id || "-"}, url=${url ? "yes" : "no"}, file=${fileName || "-"}); printing without LUT`
  );
  return null;
}

/** sidecar URL로 LUT PNG를 Pi 캐시에 받는다 */
async function downloadLutToCache(lutInfo) {
  const { id, url } = lutInfo || {};
  if (!url || !LUT_ALLOW_DOWNLOAD) return null;
  const cachePath = id
    ? path.join(LUT_CACHE_DIR, `${safeCacheNamePart(id)}.png`)
    : path.join(LUT_CACHE_DIR, `${safeCacheNamePart("custom")}.png`);
  try {
    const tmp = `${cachePath}.tmp-${process.pid}-${Date.now()}`;
    await downloadFileHttp(url, tmp);
    if (!existsNonEmpty(tmp)) {
      try { fs.unlinkSync(tmp); } catch (_) {}
      return null;
    }
    if (existsNonEmpty(cachePath)) invalidateLutCacheFile(cachePath);
    fs.renameSync(tmp, cachePath);
    writeLutCacheMetaFile(getLutMetaPath(cachePath), { id: id || "", url });
    invalidateLutDataCache(cachePath);
    console.log(`[LUT] downloaded -> ${path.basename(cachePath)}`);
    return cachePath;
  } catch (e) {
    console.warn(`[LUT] download failed (${url}): ${e.message || e}`);
    return null;
  }
}

/** LUT 로드 + probe 검증. USB/캐시 파일이 identity면 URL에서 재다운로드 */
async function loadValidatedLut(dir, docId, lutInfo, resolved) {
  const tryPath = async (localPath, source) => {
    invalidateLutDataCache(localPath);
    const lutData = await loadLutImageData(localPath);
    const lut = { ...lutData, strength: resolved.strength };
    const probeDelta = measureLutAverageDelta(lut, lut.strength ?? 1);
    console.log(
      `[LUT] probe delta=${probeDelta.toFixed(2)} source=${source} file=${path.basename(localPath)}`
    );
    return { lut, localPath, source, probeDelta };
  };

  let loaded = await tryPath(resolved.localPath, resolved.source || "?");
  if (loaded.probeDelta >= 1.5) return loaded;

  console.warn(
    `[LUT] probe delta too low (${loaded.probeDelta.toFixed(2)}) — LUT PNG may be corrupt/identity; trying URL`
  );
  if (lutInfo?.url) {
    const dlPath = await downloadLutToCache(lutInfo);
    if (dlPath && dlPath !== resolved.localPath) {
      loaded = await tryPath(dlPath, "download");
    }
  }
  if (loaded.probeDelta < 1.5) {
    console.warn(
      `[LUT] warning: LUT still weak after fallback (delta=${loaded.probeDelta.toFixed(2)}) — check lut PNG on iPad`
    );
  }
  return loaded;
}

/**
 * 사이드카 LUT 정보가 없을 때, 관례적 LUT PNG가 USB로 함께 전달됐는지 "조용히" 확인.
 */
function probeConventionalLut(dir, docId) {
  const candidates = [];
  if (docId) candidates.push(path.join(dir, `${docId}_lut.png`));
  candidates.push(path.join(dir, "lut.png"));
  for (const c of candidates) {
    if (existsNonEmpty(c)) {
      return { localPath: c, strength: 1 };
    }
  }
  return null;
}

/** Compose selected JPEGs into the frame/layout canvas and print via CUPS
 *  If grayscale=true, all layers (photos + frame) are converted to grayscale.
 *  If a LUT is resolved (offline-first), it is applied to each photo before compositing.
 */
async function composeAndPrint(dir, framePng, docId, indices, copies, grayscale, sidecarMeta = null) {
  const jobId = `${docId}-${Date.now()}`;
  const tmpDir = `/tmp/usbprint-${jobId}`;
  await fsp.mkdir(tmpDir, { recursive: true });

  const debugSessionDir = USB_PRINT_DEBUG ? await createDebugSessionDir(docId) : null;
  const debugInfo = {
    docId,
    copies,
    indices,
    grayscale,
    savedAt: new Date().toISOString(),
    debugSessionDir,
    lut: null,
    slots: [],
  };

  if (debugSessionDir) {
    console.log(`[Debug] session dir: ${debugSessionDir}`);
    await copyToDebug(debugSessionDir, "inputs/frame_from_usb.png", framePng);
    await writeDebugJson(debugSessionDir, "sidecar-meta.json", sidecarMeta || {});
  }

  try {
    const meta = sidecarMeta || {};
    const canvasW = meta.canvasW || CANVAS_W;
    const canvasH = meta.canvasH || CANVAS_H;
    const dynamicSlots = Array.isArray(meta.slots) && meta.slots.length > 0 ? meta.slots : null;
    const slots = dynamicSlots || POSITIONS.map((position, index) => ({
      index,
      left: position.left,
      top: position.top,
      width: SLOT_W,
      height: SLOT_H,
    }));
    const slotCount = slots.length;
    const isHalfWidthLayout = Boolean(meta.isHalfWidthLayout);
    const requestedCopies = Math.max(1, Math.round(Number(copies) || 1));
    const physicalCopies = isHalfWidthLayout
      ? Math.max(1, Math.ceil(requestedCopies / 2))
      : requestedCopies;

    // Normalize selected indices to 1-based because JPEGs are named pictures1..6
    const oneBased = normalizeToOneBased(indices);

    // --- 0) Resolve account LUT (offline-first). null이면 v3와 동일하게 LUT 미적용 ---
    let lut = null;
    let lutSourcePath = null;
    let lutProbeDelta = null;
    try {
      const lutInfo = extractLutInfo(meta);
      const resolved = lutInfo
        ? await resolveLutForJob(dir, docId, lutInfo)
        : probeConventionalLut(dir, docId);
      if (resolved) {
        const validated = lutInfo
          ? await loadValidatedLut(dir, docId, lutInfo, resolved)
          : {
              lut: {
                ...(await loadLutImageData(resolved.localPath)),
                strength: resolved.strength,
              },
              localPath: resolved.localPath,
              probeDelta: null,
            };
        lut = validated.lut;
        lutSourcePath = validated.localPath || resolved.localPath;
        lutProbeDelta = validated.probeDelta ?? null;
        console.log(
          `[LUT] ${docId} loaded ${path.basename(lutSourcePath)} ` +
            `(${lut.width}x${lut.height}, size=${lut.lutSize}, source=${resolved.source || "?"})`
        );
        if (debugSessionDir && lutSourcePath) {
          await copyToDebug(
            debugSessionDir,
            `lut/${path.basename(lutSourcePath)}`,
            lutSourcePath
          );
        }
        debugInfo.lut = {
          file: lutSourcePath ? path.basename(lutSourcePath) : null,
          source: resolved.source || null,
          width: lut.width,
          height: lut.height,
          lutSize: lut.lutSize,
          strength: lut.strength ?? null,
          probeDelta: lutProbeDelta,
          lutPresetId: meta.lutPresetId || meta.accountLut?.id || null,
          lutStrength: meta.lutStrength ?? null,
          lutStrengths: meta.lutStrengths ?? null,
        };
      }
    } catch (e) {
      console.warn(`[LUT] ${docId} LUT load failed, printing without LUT: ${e.message || e}`);
      lut = null;
    }

    // --- 1) Resize → LUT (print-v25 와 동일 2단계) → slot JPEG ---
    const dstPics = [];
    let lutAppliedSlots = 0;
    let firstPhotoDelta = null;
    for (let i = 0; i < Math.min(oneBased.length, slotCount); i++) {
      const picNum = oneBased[i]; // 1..6
      const src = await resolvePicturePath(dir, docId, picNum);
      if (!src) throw new Error(`Missing source JPEG for pictures${picNum}`);
      const dst = path.join(tmpDir, `pic${i}.jpg`);
      const resizedPath = path.join(tmpDir, `pic${i}-resized.jpg`);
      const slot = slots[i];
      const targetW = Math.max(1, Math.round(Number(slot.width) + SLOT_OVERFLOW_PX * 2));
      const targetH = Math.max(1, Math.round(Number(slot.height) + SLOT_OVERFLOW_PX * 2));

      await sharp(src)
        .rotate()
        .withMetadata({ orientation: undefined })
        .resize(targetW, targetH, { fit: "cover", fastShrinkOnLoad: false })
        .jpeg(PRINT_JPEG_OPTIONS)
        .toFile(resizedPath);

      const slotDebug = {
        slotIndex: i,
        pictureIndex: picNum,
        sourceUsb: src,
        strength: null,
        pixelDelta: null,
        lutApplied: false,
      };

      if (debugSessionDir) {
        await copyToDebug(
          debugSessionDir,
          `photos/slot${i}_pic${picNum}_00_source_usb.jpg`,
          src
        );
        await copyToDebug(
          debugSessionDir,
          `photos/slot${i}_pic${picNum}_01_before_lut.jpg`,
          resizedPath
        );
      }

      if (lut) {
        const photoStrength = resolvePhotoLutStrength(meta, i, lut.strength ?? 1);
        slotDebug.strength = photoStrength;
        if (photoStrength > 0) {
          const avgDelta = await applyLutToJpegPath(resizedPath, dst, lut, photoStrength);
          slotDebug.pixelDelta = avgDelta;
          slotDebug.lutApplied = true;
          if (firstPhotoDelta === null) firstPhotoDelta = avgDelta;
          lutAppliedSlots += 1;
          if (grayscale) {
            const grayPath = path.join(tmpDir, `pic${i}-gray.jpg`);
            await sharp(dst).grayscale().jpeg(PRINT_JPEG_OPTIONS).toFile(grayPath);
            await fsp.rename(grayPath, dst);
          }
        } else {
          let pipeline = sharp(resizedPath);
          if (grayscale) pipeline = pipeline.grayscale();
          await pipeline.jpeg(PRINT_JPEG_OPTIONS).toFile(dst);
        }
      } else {
        let pipeline = sharp(resizedPath);
        if (grayscale) pipeline = pipeline.grayscale();
        await pipeline.jpeg(PRINT_JPEG_OPTIONS).toFile(dst);
      }

      if (debugSessionDir) {
        await copyToDebug(
          debugSessionDir,
          `photos/slot${i}_pic${picNum}_02_after_lut.jpg`,
          dst
        );
      }
      debugInfo.slots.push(slotDebug);

      dstPics.push(dst);
    }
    if (lut && lutAppliedSlots === 0) {
      console.warn(
        `[LUT] ${docId} warning: LUT file loaded but all slot strengths are 0 — printing without color grade`
      );
    } else if (lut) {
      console.log(
        `[LUT] ${docId} applied to ${lutAppliedSlots}/${Math.min(oneBased.length, slotCount)} photo slot(s)` +
          (firstPhotoDelta !== null ? `, photo pixel delta≈${firstPhotoDelta.toFixed(2)}` : "")
      );
    }
    if (dstPics.length !== slotCount) {
      throw new Error(`Expected ${slotCount} pictures, got ${dstPics.length}`);
    }

    // --- 2) Prepare frame (apply grayscale if requested) ---
    const frameForCanvas = path.join(tmpDir, `frame-canvas.png`);
    await sharp(framePng)
      .resize(canvasW, canvasH, { fit: "fill", fastShrinkOnLoad: false })
      .toFile(frameForCanvas);

    let frameInput = frameForCanvas;
    if (grayscale) {
      const grayFrame = path.join(tmpDir, `frame-gray.png`);
      await sharp(frameInput).grayscale().toFile(grayFrame);
      frameInput = grayFrame;
    }

    // --- 3) Composite photos + frame on a white canvas ---
    const composites = dstPics.map((p, i) => ({
      input: p,
      left: Math.round((Number(slots[i].left) || 0) - SLOT_OVERFLOW_PX),
      top: Math.round((Number(slots[i].top) || 0) - SLOT_OVERFLOW_PX),
      blend: "over",
    }));
    composites.push({ input: frameInput, left: 0, top: 0, blend: "over" });

    const outJpg = path.join(tmpDir, `composite.jpg`);
    await sharp({
      create: {
        width: canvasW,
        height: canvasH,
        channels: 3,
        background: { r: 255, g: 255, b: 255 },
      },
    })
      .composite(composites)
      .jpeg(PRINT_JPEG_OPTIONS)
      .toFile(outJpg);

    let printInputPath = outJpg;
    if (isHalfWidthLayout) {
      const twoUpPath = path.join(tmpDir, `composite-2up.jpg`);
      const leftHalfResizedPath = path.join(tmpDir, `composite-half-left-fit.jpg`);
      const rightHalfResizedPath = path.join(tmpDir, `composite-half-right-fit.jpg`);

      await sharp(outJpg)
        .resize(HALF_WIDTH_TWO_UP_LEFT_IMAGE_WIDTH, HALF_WIDTH_TWO_UP_IMAGE_HEIGHT, {
          fit: "fill",
          fastShrinkOnLoad: false,
        })
        .jpeg(PRINT_JPEG_OPTIONS)
        .toFile(leftHalfResizedPath);

      await sharp(outJpg)
        .resize(HALF_WIDTH_TWO_UP_RIGHT_IMAGE_WIDTH, HALF_WIDTH_TWO_UP_IMAGE_HEIGHT, {
          fit: "fill",
          fastShrinkOnLoad: false,
        })
        .jpeg(PRINT_JPEG_OPTIONS)
        .toFile(rightHalfResizedPath);

      await sharp({
        create: {
          width: HALF_WIDTH_TWO_UP_OUTPUT_WIDTH,
          height: CANVAS_H,
          channels: 3,
          background: { r: 255, g: 255, b: 255 },
        },
      })
        .composite([
          {
            input: leftHalfResizedPath,
            left: HALF_WIDTH_TWO_UP_LEFT_X,
            top: HALF_WIDTH_TWO_UP_IMAGE_TOP,
            blend: "over",
          },
          {
            input: rightHalfResizedPath,
            left: HALF_WIDTH_TWO_UP_RIGHT_X,
            top: HALF_WIDTH_TWO_UP_IMAGE_TOP,
            blend: "over",
          },
        ])
        .jpeg(PRINT_JPEG_OPTIONS)
        .toFile(twoUpPath);

      printInputPath = twoUpPath;
      console.log(
        `[Print] ${docId} half-width 2-up: requested=${requestedCopies}, CUPS sheets=${physicalCopies}, output=${HALF_WIDTH_TWO_UP_OUTPUT_WIDTH}x${CANVAS_H}`
      );
    }

    debugInfo.layout = {
      canvasW,
      canvasH,
      isHalfWidthLayout,
      requestedCopies,
      physicalCopies,
      firstPhotoDelta,
      lutAppliedSlots,
    };

    if (debugSessionDir) {
      await copyToDebug(debugSessionDir, "composite/00_canvas_composite.jpg", outJpg);
      if (isHalfWidthLayout) {
        await copyToDebug(debugSessionDir, "composite/01_final_2x6_before_print.jpg", printInputPath);
      } else {
        await copyToDebug(debugSessionDir, "composite/01_final_4x6_before_print.jpg", printInputPath);
      }
      await writeDebugJson(debugSessionDir, "debug-info.json", debugInfo);
      console.log(`[Debug] saved (print skipped): ${debugSessionDir}`);
      console.log(`[Debug] compare LUT: photos/*_01_before_lut.jpg vs *_02_after_lut.jpg`);
      return;
    }

    const compositeStat = await fsp.stat(printInputPath);
    console.log(
      `[Print] ${docId} composite ready: ${compositeStat.size} bytes, ${canvasW}x${canvasH}, copies=${physicalCopies}`
    );

    // --- 4) Convert to PNM and print (print-v25.mjs 와 동일: ICC + PageSize) ---
    const outPnm = path.join(tmpDir, `composite.pnm`);
    await convertJpegToPnmForPrint(docId, printInputPath, outPnm, "composite", grayscale);

    const lpCmd = [
      "lp",
      "-d", PRINTER_NAME,
      "-n", `${physicalCopies}`,
      "-o", "StpiShrinkOutput=Shrink",
      "-o", "Resolution=300x600dpi",
      "-o", isHalfWidthLayout ? "PageSize=w288h432-div2" : "PageSize=w288h432",
    ];
    if (isHalfWidthLayout) {
      lpCmd.push("-o", "fit-to-page=true");
    }
    if (grayscale) lpCmd.push("-o", "ColorModel=Gray");
    lpCmd.push("-o", "document-format=image/x-portable-anymap");
    lpCmd.push(`"${outPnm}"`);

    const { stdout } = await exec(lpCmd.join(" "));
    const jobTag = parseLpJobTag(stdout);
    console.log(
      `[Print] ${docId} ${grayscale ? "(grayscale)" : ""} ${isHalfWidthLayout ? "(2x6)" : ""} -> lp: ${stdout.trim()}`
    );
    if (jobTag) {
      const cupsOk = await waitForCupsJobComplete(jobTag);
      if (!cupsOk) {
        console.warn(
          `[Print] ${docId} CUPS wait ended without confirmed completion (${jobTag})`
        );
      }
    } else {
      console.warn(`[Print] ${docId} could not parse CUPS job id from lp output`);
    }
    console.log(`[Print] ${docId} completed`);
  } finally {
    try { await fsp.rm(tmpDir, { recursive: true, force: true }); } catch {}
  }
}

/** Poll a specific MyCutBox directory (for a single UDID mount) */
async function pollDir(absDir) {
  if (!watchers.has(absDir)) {
    watchers.set(absDir, { running: true, lastScan: 0 });
    console.log(`[Watch] Start: ${absDir}`);
  }
  const state = watchers.get(absDir);

  while (state.running) {
    try {
      const files = await fsp.readdir(absDir);

      for (const f of files) {
        // Only pick fresh jobs: ^printThis_
        if (!/^printThis_/i.test(f)) continue;

        const abs = path.join(absDir, f);
        //if (seen.has(abs)) continue;

        // Parse BEFORE renaming (easier)
        const meta = parsePrintThis(f);
        if (!meta) continue;
        let sidecarMeta = await readUsbPrintSidecar(abs, meta);
        if (!sidecarMeta) {
          await sleep(300);
          sidecarMeta = await readUsbPrintSidecar(abs, meta);
        }
        const effectiveMeta = sidecarMeta || meta;

        // Basic size-stability check to avoid half-written file
        let s1 = 0, s2 = 0;
        try { s1 = (await fsp.stat(abs)).size; } catch { continue; }
        await sleep(400);
        try { s2 = (await fsp.stat(abs)).size; } catch { continue; }
        if (s1 !== s2 || s2 === 0) continue;

        // Lock it atomically -> processing_*
        let lockedPath;
        try {
          lockedPath = await markProcessing(abs);
        } catch (e) {
          // If rename fails (e.g., file vanished), skip
          console.warn(`[Lock] Failed to rename to processing_: ${abs}`, e.message || e);
          continue;
        }

        // Also mark both paths as seen for this run
        seen.set(abs, Date.now());
        seen.set(lockedPath, Date.now());

        console.log(`[Detect] ${abs} -> ${path.basename(lockedPath)}`);
        const { copies, docId, indices, grayscale } = effectiveMeta;

        try {
          await composeAndPrint(absDir, lockedPath, docId, indices, copies, grayscale, effectiveMeta);
          await markCompleted(lockedPath);
          console.log(`[Done] Marked as completed`);
        } catch (err) {
          console.error(`[Error] compose/print failed for ${lockedPath}:`, err.message || err);
          try {
            await markFailed(lockedPath);
            console.log(`[Fail] Marked as failed`);
          } catch (e2) {
            console.error(`[Fail] Mark-failed rename error:`, e2.message || e2);
          }
        }
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

/** Scans GVFS base and starts a watcher for each AFC mount's MyCutBox path */
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
          try { await fsp.access(appDir, fs.constants.R_OK); } catch { continue; }
          pollDir(appDir);
        }
      }
      // disappearing mounts are handled inside pollDir
    } catch (err) {
      console.error("[MountScan] error:", err);
    }
    await sleep(POLL_MS_MOUNTS);
  }
}

// ====== MAIN ======
(async () => {
  console.log(`[Init] GVFS_BASE=${GVFS_BASE}, printer=${PRINTER_NAME}`);
  console.log(`[Init] Watching AFC mounts: ${AFC_PREFIX}* / ${APP_REL_DIRS.join(" | ")}`);
  console.log(`[Init] LUT cache dir: ${LUT_CACHE_DIR} (download=${LUT_ALLOW_DOWNLOAD ? "on" : "off"})`);
  console.log(`[Init] ICC cache dir: ${ICC_CACHE_DIR}${USB_PRINTER_ICC_PATH ? `, override=${USB_PRINTER_ICC_PATH}` : ""}`);
  if (USB_PRINT_DEBUG) {
    console.log(`[Init] DEBUG MODE ON: print DISABLED — saving to ${USB_DEBUG_BASE_DIR}`);
    console.log(`[Init] 인화 재개: usbPrint.cjs 상단 USB_PRINT_DEBUG = false 로 변경 후 restart`);
  } else {
    console.log(`[Init] DEBUG MODE OFF: normal USB printing enabled`);
  }
  console.log(`[Hint] Run as the desktop user (uid=1000) so GVFS paths are visible.`);
  await scanMountsLoop();
})();
