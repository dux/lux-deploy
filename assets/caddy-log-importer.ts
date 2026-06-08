// Generic single-writer importer: tails every site's Caddy JSON access log
// and batch-inserts into that site's SQLite. Installed + run as ONE host-wide
// systemd service by `caddy:log:prepare`; it scans <apps>/*/log/<domain>.jsonl
// and writes each into the sibling caddy.sqlite, auto-picking up new sites.
//
// Crash-safe: each batch inserts rows AND advances the (inode, offset)
// checkpoint in ONE transaction. A restart replays at most the last
// un-checkpointed bytes; event_id = sha256(line) + INSERT OR IGNORE dedups.
import { Database } from "bun:sqlite";
import { openSync, fstatSync, statSync, readSync, closeSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

const FLUSH_MS = 10_000, FLUSH_ROWS = 5000, PRUNE_MS = 3_600_000;

function parseArgs() {
  const a = process.argv.slice(2);
  let scan = "", db = "", cmd: "run" | "stats" = "run", retentionDays = 30;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "stats") cmd = "stats";
    else if (a[i] === "--scan") scan = a[++i];
    else if (a[i] === "--db") db = a[++i];
    else if (a[i] === "--retention-days") retentionDays = parseInt(a[++i], 10) || 0;
  }
  if (cmd === "stats" && !db) { console.error("usage: caddy-log-importer.ts stats --db <path>"); process.exit(2); }
  if (cmd === "run" && !scan)  { console.error("usage: caddy-log-importer.ts --scan <apps_dir> [--retention-days N]"); process.exit(2); }
  return { scan, db, cmd, retentionDays };
}

function openDb(path: string): Database {
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode=WAL;");
  db.exec("PRAGMA synchronous=NORMAL;");
  db.exec("PRAGMA busy_timeout=5000;");
  db.exec(`
    CREATE TABLE IF NOT EXISTS import_state (
      source TEXT PRIMARY KEY, inode INTEGER NOT NULL,
      offset INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS access_log (
      event_id TEXT PRIMARY KEY, ts TEXT, remote_ip TEXT, user_ip TEXT, country TEXT,
      method TEXT, host TEXT, uri TEXT, status INTEGER, duration REAL,
      size INTEGER, lux_speed INTEGER, content_length INTEGER,
      user_agent TEXT, referer TEXT, raw_json TEXT NOT NULL);`);
  // Migrate DBs created before a column existed: add any missing one. Must run
  // BEFORE the indexes below, or an index on a not-yet-added column throws.
  const have = new Set(db.query("PRAGMA table_info(access_log)").all().map((r: any) => r.name));
  for (const [name, type] of [["user_ip", "TEXT"], ["lux_speed", "INTEGER"], ["content_length", "INTEGER"]]) {
    if (!have.has(name)) db.exec(`ALTER TABLE access_log ADD COLUMN ${name} ${type}`);
  }
  db.exec(`
    CREATE INDEX IF NOT EXISTS access_log_ts_idx ON access_log(ts);
    CREATE INDEX IF NOT EXISTS access_log_host_idx ON access_log(host);
    CREATE INDEX IF NOT EXISTS access_log_status_idx ON access_log(status);
    CREATE INDEX IF NOT EXISTS access_log_country_idx ON access_log(country);
    CREATE INDEX IF NOT EXISTS access_log_user_ip_idx ON access_log(user_ip);`);
  return db;
}

const sha256 = (s: string) => new Bun.CryptoHasher("sha256").update(s).digest("hex");
const h = (hdrs: any, name: string) => (hdrs?.[name]?.[0] ?? null);

// caddy json access entry -> column tuple; raw line preserved verbatim,
// columns best-effort (a non-JSON line still stores raw_json). Behind
// Cloudflare the real visitor IP + country live in CF-* request headers
// (request.remote_ip is the CF edge), so prefer those.
function extract(line: string) {
  let o: any = {};
  try { o = JSON.parse(line); } catch {}
  const r = o.request ?? {};
  const hd = r.headers ?? {};
  const rh = o.resp_headers ?? {};
  const speed = parseFloat(h(rh, "X-Lux-Speed"));      // "65.2ms" -> 65
  const clen  = parseInt(h(rh, "Content-Length"), 10);
  return {
    $event_id: sha256(line),
    $ts: o.ts != null ? String(o.ts) : null,
    $remote_ip: r.remote_ip ?? r.client_ip ?? null,                 // connection peer (CF edge)
    $user_ip: h(hd, "Cf-Connecting-Ip") ?? r.client_ip ?? r.remote_ip ?? null,  // real visitor
    $country: h(hd, "Cf-Ipcountry"),
    $method: r.method ?? null, $host: r.host ?? null, $uri: r.uri ?? null,
    $status: o.status ?? null, $duration: o.duration ?? null,
    $size: o.size ?? null,
    $lux_speed: Number.isFinite(speed) ? Math.round(speed) : null,
    $content_length: Number.isFinite(clen) ? clen : null,
    $user_agent: h(hd, "User-Agent"), $referer: h(hd, "Referer"),
    $raw_json: line,
  };
}

// Per-site tail state: its own DB, prepared statements, open fd + checkpoint.
type Src = {
  jsonl: string; db: Database; insert: any; checkpoint: any; prune: any;
  fd: number; inode: number; committed: number;
  readOffset: number; carry: Buffer; pending: any[];
};

function openLog(s: Src) {
  try {
    s.fd = openSync(s.jsonl, "r");
    const f = fstatSync(s.fd);
    if (f.ino !== s.inode) { s.inode = f.ino; s.committed = 0; s.readOffset = 0; s.carry = Buffer.alloc(0); }
  } catch { s.fd = -1; }
}

function openSource(jsonl: string): Src {
  const db = openDb(join(dirname(jsonl), "caddy.sqlite"));
  const insert = db.prepare(
    `INSERT OR IGNORE INTO access_log
       (event_id,ts,remote_ip,user_ip,country,method,host,uri,status,duration,size,lux_speed,content_length,user_agent,referer,raw_json)
     VALUES ($event_id,$ts,$remote_ip,$user_ip,$country,$method,$host,$uri,$status,$duration,$size,$lux_speed,$content_length,$user_agent,$referer,$raw_json)`);
  const checkpoint = db.prepare(
    `INSERT INTO import_state (source,inode,offset,updated_at)
       VALUES ($source,$inode,$offset,$now)
     ON CONFLICT(source) DO UPDATE SET inode=$inode, offset=$offset, updated_at=$now`);
  // ts is the caddy unix-epoch (seconds); CAST so the TEXT column compares numerically.
  const prune = db.prepare("DELETE FROM access_log WHERE CAST(ts AS REAL) < $cutoff");
  const st: any = db.query("SELECT inode,offset FROM import_state WHERE source=?").get(jsonl);
  const s: Src = {
    jsonl, db, insert, checkpoint, prune, fd: -1,
    inode: st?.inode ?? 0, committed: st?.offset ?? 0,
    readOffset: st?.offset ?? 0, carry: Buffer.alloc(0), pending: [],
  };
  openLog(s);
  return s;
}

function flush(s: Src) {
  const safe = s.readOffset - s.carry.length;   // offset of last complete line
  const rows = s.pending;
  s.db.transaction(() => {
    for (const r of rows) s.insert.run(r);
    s.checkpoint.run({ $source: s.jsonl, $inode: s.inode, $offset: safe, $now: Date.now() });
  })();
  s.committed = safe; s.pending = [];
}

const BUF = Buffer.allocUnsafe(1 << 20);
function drain(s: Src) {
  if (s.fd < 0) { openLog(s); if (s.fd < 0) return; }
  let rotated = false;
  try { rotated = statSync(s.jsonl).ino !== s.inode; } catch {}
  let n: number;
  do {
    n = readSync(s.fd, BUF, 0, BUF.length, s.readOffset);
    if (n > 0) {
      s.readOffset += n;
      s.carry = Buffer.concat([s.carry, BUF.subarray(0, n)]);
      let nl: number;
      while ((nl = s.carry.indexOf(0x0a)) >= 0) {
        const line = s.carry.subarray(0, nl).toString("utf8");
        s.carry = s.carry.subarray(nl + 1);
        if (line.length) s.pending.push(extract(line));
        if (s.pending.length >= FLUSH_ROWS) flush(s);
      }
    }
  } while (n > 0);
  if (rotated) {                        // fd drained to EOF -> switch files
    flush(s);
    closeSync(s.fd);
    s.carry = Buffer.alloc(0); s.inode = 0; s.readOffset = 0; s.committed = 0;
    openLog(s);
  }
}

// Drop rows past the retention window, then truncate the WAL so the file
// actually shrinks. Cheap when there's nothing to delete.
function prune(s: Src, days: number) {
  if (days <= 0) return;
  const cutoff = Date.now() / 1000 - days * 86400;
  s.prune.run({ $cutoff: cutoff });
  s.db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
}

// Active log per site is <apps>/<domain>/log/<domain>.jsonl (matches the
// caddy.conf {{LOG_DIR}}/{{LOG_NAME}}.jsonl render). Rolled files carry a
// timestamp suffix, so this exact name only ever points at the live file.
function discover(scanRoot: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(scanRoot, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name);
  } catch { return []; }
  const out: string[] = [];
  for (const name of names) {
    const jsonl = join(scanRoot, name, "log", `${name}.jsonl`);
    if (existsSync(jsonl)) out.push(jsonl);
  }
  return out;
}

function runImporter(scanRoot: string, retentionDays: number) {
  const sources = new Map<string, Src>();
  const stop = () => {
    for (const s of sources.values()) {
      try { flush(s); } catch {}
      if (s.fd >= 0) { try { closeSync(s.fd); } catch {} }
    }
    process.exit(0);
  };
  process.on("SIGTERM", stop); process.on("SIGINT", stop);

  let lastFlush = Date.now(), lastPrune = Date.now();
  (async () => { for (;;) {
    for (const jsonl of discover(scanRoot)) {
      if (!sources.has(jsonl)) {
        try { sources.set(jsonl, openSource(jsonl)); console.error(`watching ${jsonl}`); }
        catch (e) { console.error(`open failed ${jsonl}: ${e}`); }
      }
    }
    for (const s of sources.values()) drain(s);
    const now = Date.now();
    if (now - lastFlush >= FLUSH_MS) {
      for (const s of sources.values()) if (s.pending.length) flush(s);
      lastFlush = now;
    }
    if (now - lastPrune >= PRUNE_MS) {
      for (const s of sources.values()) { try { prune(s, retentionDays); } catch (e) { console.error(`prune failed ${s.jsonl}: ${e}`); } }
      lastPrune = now;
    }
    await Bun.sleep(1000);
  } })();
}

function runStats(dbPath: string) {
  const db = openDb(dbPath);
  const total: any = db.query("SELECT COUNT(*) c FROM access_log").get();
  const span: any  = db.query("SELECT MIN(ts) lo, MAX(ts) hi FROM access_log").get();
  const state: any = db.query("SELECT source,inode,offset,updated_at FROM import_state").all();
  console.log(JSON.stringify({ rows: total.c, ts_min: span.lo, ts_max: span.hi, sources: state }, null, 2));
}

const args = parseArgs();
args.cmd === "stats" ? runStats(args.db) : runImporter(args.scan, args.retentionDays);
