"use strict";

// Pi-local foreground leases let independent USB watchers avoid competing for
// the same AFC directory. Nothing is written into the iPad's Documents folder.
const fs = require("node:fs/promises");
const path = require("node:path");
const { createHash, randomBytes } = require("node:crypto");

const WIFI_ACTIVITY_TTL_MS = 30_000;
const RECORD_NAME = /^[a-f0-9]{64}\.json$/;

function createWifiActivity({ directory, now = Date.now } = {}) {
  const runtimeDirectory = directory || path.join(
    process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`,
    "mycutbox-wifi"
  );
  const pending = new Map();
  const appHash = (appDir) => createHash("sha256").update(appDir).digest("hex");
  const recordPath = (hash) => path.join(runtimeDirectory, `${hash}.json`);

  // Preserve call order if a screen closes while a renewal is still writing.
  function mutate(hash, operation) {
    const previous = pending.get(hash) || Promise.resolve();
    const current = previous.then(operation, operation).catch(() => false);
    pending.set(hash, current);
    current.finally(() => {
      if (pending.get(hash) === current) pending.delete(hash);
    });
    return current;
  }

  async function readActive(hash) {
    try {
      const raw = await fs.readFile(recordPath(hash), "utf8");
      if (raw.length > 256) return false;
      const record = JSON.parse(raw);
      const age = now() - record.renewedAt;
      return record.version === 1 && record.appHash === hash &&
        Number.isFinite(record.renewedAt) && age >= 0 && age < WIFI_ACTIVITY_TTL_MS;
    } catch (_) {
      // A missing, unreadable, or interrupted lease never stops print forever.
      return false;
    }
  }

  return {
    renew(appDir) {
      const hash = appHash(appDir);
      return mutate(hash, async () => {
        await fs.mkdir(runtimeDirectory, { recursive: true, mode: 0o700 });
        const temporary = `${recordPath(hash)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
        try {
          await fs.writeFile(temporary, JSON.stringify({
            version: 1,
            appHash: hash,
            renewedAt: now(),
          }), { mode: 0o600, flag: "wx" });
          await fs.rename(temporary, recordPath(hash));
          return true;
        } finally {
          await fs.unlink(temporary).catch(() => {});
        }
      });
    },

    clear(appDir) {
      const hash = appHash(appDir);
      return mutate(hash, async () => {
        try {
          await fs.unlink(recordPath(hash));
          return true;
        } catch (error) {
          return error.code === "ENOENT";
        }
      });
    },

    isActive(appDir) {
      return readActive(appHash(appDir));
    },

    async anyActive() {
      try {
        const entries = await fs.readdir(runtimeDirectory);
        for (const entry of entries) {
          if (RECORD_NAME.test(entry) && await readActive(entry.slice(0, -5)))
            return true;
        }
      } catch (_) {}
      return false;
    },
  };
}

module.exports = { createWifiActivity, WIFI_ACTIVITY_TTL_MS };
