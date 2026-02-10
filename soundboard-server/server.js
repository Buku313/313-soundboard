const express = require("express");
const compression = require("compression");
const http = require("http");
const https = require("https");
const { WebSocketServer } = require("ws");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { URL } = require("url");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

const PORT = 3000;
const DATA_DIR = path.join(__dirname, "data");
const SOUNDS_FILE = path.join(DATA_DIR, "sounds.json");
const SOUNDS_DIR = path.join(DATA_DIR, "sounds");
const ROOM_CODE_FILE = path.join(DATA_DIR, "room-code.txt");

const MAX_FILE_SIZE = 2 * 1024 * 1024; // 2MB
const MAX_SOUNDS = 100;
const MAX_REDIRECTS = 3;
const RATE_ADD_MAX = 5;      // per minute
const RATE_PLAY_MAX = 30;    // per minute
const RATE_WINDOW_MS = 60000;
const RATE_CLEANUP_MS = 300000;
const VALID_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

// Ensure data dirs exist
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(SOUNDS_DIR, { recursive: true });

// --- Room Code ---
let ROOM_CODE;
try {
  ROOM_CODE = fs.readFileSync(ROOM_CODE_FILE, "utf8").trim();
} catch {
  ROOM_CODE = crypto.randomBytes(3).toString("hex").toUpperCase();
  fs.writeFileSync(ROOM_CODE_FILE, ROOM_CODE);
}
console.log("=== Room code: " + ROOM_CODE + " ===");

// --- In-memory Sound Cache ---
let soundsCache;
try {
  soundsCache = JSON.parse(fs.readFileSync(SOUNDS_FILE, "utf8"));
} catch {
  soundsCache = [];
}

// Migrate: ensure plays and color fields exist
let needsMigration = false;
soundsCache.forEach((s) => {
  if (s.plays === undefined) { s.plays = 0; needsMigration = true; }
  if (s.color === undefined) { s.color = null; needsMigration = true; }
});
if (needsMigration) {
  fs.writeFileSync(SOUNDS_FILE, JSON.stringify(soundsCache, null, 2));
}

function saveSounds() {
  if (playsSaveTimer) { clearTimeout(playsSaveTimer); playsSaveTimer = null; }
  fs.writeFileSync(SOUNDS_FILE, JSON.stringify(soundsCache, null, 2));
}

// Debounced save for play count increments (avoid disk thrash)
let playsSaveTimer = null;
function debouncedSave() {
  if (!playsSaveTimer) {
    playsSaveTimer = setTimeout(() => {
      fs.writeFileSync(SOUNDS_FILE, JSON.stringify(soundsCache, null, 2));
      playsSaveTimer = null;
    }, 2000);
  }
}

// --- Rate Limiting ---
const rateLimits = new Map();

function getRateEntry(ip) {
  if (!rateLimits.has(ip)) {
    rateLimits.set(ip, { adds: [], plays: [] });
  }
  return rateLimits.get(ip);
}

function checkRate(ip, type) {
  const entry = getRateEntry(ip);
  const now = Date.now();
  const max = type === "add" ? RATE_ADD_MAX : RATE_PLAY_MAX;
  const bucket = type === "add" ? entry.adds : entry.plays;

  while (bucket.length > 0 && now - bucket[0] > RATE_WINDOW_MS) {
    bucket.shift();
  }

  if (bucket.length >= max) return false;
  bucket.push(now);
  return true;
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of rateLimits) {
    entry.adds = entry.adds.filter((t) => now - t < RATE_WINDOW_MS);
    entry.plays = entry.plays.filter((t) => now - t < RATE_WINDOW_MS);
    if (entry.adds.length === 0 && entry.plays.length === 0) {
      rateLimits.delete(ip);
    }
  }
}, RATE_CLEANUP_MS);

// --- URL Validation ---
function isValidMyInstantsUrl(urlStr) {
  try {
    const u = new URL(urlStr);
    if (u.protocol !== "https:" && u.protocol !== "http:") return false;
    const host = u.hostname.toLowerCase();
    if (host !== "www.myinstants.com" && host !== "myinstants.com") return false;
    if (!/^\/instant\/[\w-]+\/?$/.test(u.pathname)) return false;
    return true;
  } catch {
    return false;
  }
}

// --- Fetch with redirect depth limit ---
function fetchText(url, depth) {
  if (depth === undefined) depth = 0;
  if (depth >= MAX_REDIRECTS) return Promise.reject(new Error("Too many redirects"));
  return new Promise((resolve, reject) => {
    const client = url.startsWith("https") ? https : http;
    const req = client.get(url, { headers: { "User-Agent": "Mozilla/5.0" } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return fetchText(res.headers.location, depth + 1).then(resolve).catch(reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error("HTTP " + res.statusCode));
      }
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve(data));
    });
    req.on("error", reject);
    req.setTimeout(10000, () => { req.destroy(); reject(new Error("timeout")); });
  });
}

// --- Download with size enforcement and redirect depth limit ---
function downloadFile(url, dest, depth) {
  if (depth === undefined) depth = 0;
  if (depth >= MAX_REDIRECTS) return Promise.reject(new Error("Too many redirects"));
  return new Promise((resolve, reject) => {
    const client = url.startsWith("https") ? https : http;
    const req = client.get(url, { headers: { "User-Agent": "Mozilla/5.0" } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return downloadFile(res.headers.location, dest, depth + 1).then(resolve).catch(reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error("HTTP " + res.statusCode));
      }

      const contentLength = parseInt(res.headers["content-length"], 10);
      if (contentLength && contentLength > MAX_FILE_SIZE) {
        res.resume();
        return reject(new Error("File too large (>" + (MAX_FILE_SIZE / 1024 / 1024) + "MB)"));
      }

      let received = 0;
      const ws = fs.createWriteStream(dest);
      let aborted = false;

      res.on("data", (chunk) => {
        received += chunk.length;
        if (received > MAX_FILE_SIZE && !aborted) {
          aborted = true;
          res.destroy();
          ws.destroy();
          try { fs.unlinkSync(dest); } catch {}
          reject(new Error("File too large (>" + (MAX_FILE_SIZE / 1024 / 1024) + "MB)"));
        }
      });

      res.pipe(ws);
      ws.on("finish", () => { if (!aborted) ws.close(resolve); });
      ws.on("error", (err) => { if (!aborted) reject(err); });
    });
    req.on("error", reject);
    req.setTimeout(15000, () => { req.destroy(); reject(new Error("timeout")); });
  });
}

// --- Scrape MyInstants ---
async function scrapeMyInstants(url) {
  const cleanUrl = url.split("?")[0].replace(/\/$/, "") + "/";
  const html = await fetchText(cleanUrl);

  const mp3Match = html.match(/\/media\/sounds\/[^"'\s]+\.mp3/);
  if (!mp3Match) throw new Error("Could not find MP3 on page");

  const titleMatch = html.match(/<title>([^<]+)/);
  const title = titleMatch
    ? titleMatch[1].replace(/ - Instant Sound Effect Button \| Myinstants/i, "").trim()
    : "Unknown Sound";

  return { title, mp3Url: "https://www.myinstants.com" + mp3Match[0] };
}

// --- Auth middleware ---
function requireRoom(req, res, next) {
  const code = req.query.room;
  if (!code || code.toUpperCase() !== ROOM_CODE) {
    return res.status(403).json({ error: "Invalid room code" });
  }
  next();
}

// --- Sanitize username ---
function sanitizeUsername(name) {
  if (!name || typeof name !== "string") return "Someone";
  const clean = name.replace(/<[^>]*>/g, "").trim();
  if (clean.length === 0) return "Someone";
  return clean.substring(0, 30);
}

// --- Broadcast ---
function broadcast(data) {
  const msg = JSON.stringify(data);
  wss.clients.forEach((client) => {
    if (client.readyState === 1) client.send(msg);
  });
}

// --- Middleware ---
app.use(compression());
app.use(express.json());

// Security headers
app.use((req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "ALLOWALL");
  res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
  res.setHeader("Content-Security-Policy",
    "default-src 'self'; " +
    "script-src 'self' 'unsafe-inline'; " +
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src 'self' https://fonts.gstatic.com; " +
    "img-src 'self' data:; " +
    "media-src 'self'; " +
    "connect-src 'self' ws: wss:;"
  );
  next();
});

// Static sound files with immutable caching
app.use("/sounds", express.static(SOUNDS_DIR, { maxAge: "1y", immutable: true }));

// Serve frontend
app.use(express.static(path.join(__dirname, "public")));

// --- API Routes ---

app.get("/api/sounds", requireRoom, (req, res) => {
  res.json(soundsCache);
});

app.post("/api/sounds", requireRoom, async (req, res) => {
  const ip = req.ip;
  if (!checkRate(ip, "add")) {
    return res.status(429).json({ error: "Rate limit: max " + RATE_ADD_MAX + " adds per minute" });
  }

  const { url } = req.body;
  if (!url || !isValidMyInstantsUrl(url)) {
    return res.status(400).json({ error: "Invalid URL. Must be a myinstants.com/instant/SLUG/ link." });
  }

  if (soundsCache.length >= MAX_SOUNDS) {
    return res.status(400).json({ error: "Sound limit reached (" + MAX_SOUNDS + " max)" });
  }

  try {
    const { title, mp3Url } = await scrapeMyInstants(url);
    const id = crypto.randomBytes(6).toString("hex");
    const filename = id + ".mp3";
    const localPath = path.join(SOUNDS_DIR, filename);

    await downloadFile(mp3Url, localPath);

    const sound = { id, title, filename, source: url.split("?")[0], plays: 0, color: null };
    soundsCache.push(sound);
    saveSounds();

    broadcast({ type: "sound_added", sound });
    res.json(sound);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete("/api/sounds/:id", requireRoom, (req, res) => {
  const idx = soundsCache.findIndex((s) => s.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: "Not found" });

  const [removed] = soundsCache.splice(idx, 1);
  saveSounds();

  const filepath = path.join(SOUNDS_DIR, removed.filename);
  try { fs.unlinkSync(filepath); } catch {}

  broadcast({ type: "sound_removed", id: removed.id });
  res.json({ ok: true });
});

// Set sound color
app.patch("/api/sounds/:id/color", requireRoom, (req, res) => {
  const sound = soundsCache.find((s) => s.id === req.params.id);
  if (!sound) return res.status(404).json({ error: "Not found" });

  const { color } = req.body;
  if (color !== null && !VALID_COLOR_RE.test(color)) {
    return res.status(400).json({ error: "Invalid color format" });
  }

  sound.color = color;
  saveSounds();
  broadcast({ type: "sound_updated", id: sound.id, color: sound.color });
  res.json({ ok: true });
});

// --- WebSocket upgrade with room validation ---
server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url, "http://localhost");
  const code = url.searchParams.get("room");

  if (!code || code.toUpperCase() !== ROOM_CODE) {
    socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit("connection", ws, req);
  });
});

wss.on("connection", (ws, req) => {
  const ip = req.headers["x-forwarded-for"]
    ? req.headers["x-forwarded-for"].split(",")[0].trim()
    : req.socket.remoteAddress;

  ws.send(JSON.stringify({ type: "init", sounds: soundsCache }));

  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw);
      if (msg.type === "play") {
        if (!checkRate(ip, "play")) {
          ws.send(JSON.stringify({ type: "error", error: "Rate limit: slow down on plays" }));
          return;
        }
        const sound = soundsCache.find((s) => s.id === msg.id);
        if (!sound) return;

        sound.plays = (sound.plays || 0) + 1;
        debouncedSave();

        const user = sanitizeUsername(msg.user);
        broadcast({ type: "play", id: msg.id, user: user, plays: sound.plays });
      }
    } catch {}
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log("Soundboard running on http://0.0.0.0:" + PORT);
});
