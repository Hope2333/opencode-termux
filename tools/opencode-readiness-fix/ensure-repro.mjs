// Minimal repro of opencode client Service.ensure() readiness handshake.
// Mirrors packages/client/src/effect/service.ts ensure() + service-contender.ts spawn.
// Usage: bun ensure-repro.mjs <opencode-binary> [--isolate]
//   --isolate: point XDG_* at a temp sandbox (do NOT touch resident state)
import { spawn } from "node:child_process"
import { readFile, rm, mkdir } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

const BIN = process.argv[2]
const ISOLATE = process.argv.includes("--isolate")
if (!BIN) { console.error("usage: bun ensure-repro.mjs <binary> [--isolate]"); process.exit(2) }

if (ISOLATE) {
  const sandbox = join(process.env.TMPDIR ?? "/tmp", "ensure-repro-" + Date.now())
  for (const k of ["XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]) process.env[k] = join(sandbox, k.slice(4).toLowerCase())
  for (const k of ["XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]) await mkdir(process.env[k], { recursive: true })
  console.log("[repro] sandbox:", sandbox)
}
// The opencode1 launcher re-roots XDG_*: <XDG_STATE_HOME>/opencode1/opencode/service.json.
const nest = process.env.REPRO_NEST ?? "opencode"
const FILE = join(process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"), nest, "opencode", "service.json")
console.log("[repro] binary:", BIN)
console.log("[repro] registration file:", FILE)

const T = { pollInterval: 25, requestTimeout: 2000, spawnDelay: 5000, maxSpawnDelay: 30000, promiseTimeout: 30000 }
const deadline = Date.now() + T.promiseTimeout // 30s: enough for a healthy machine; oscar baseline says listen <20s
const contenders = new Set()
let lastSpawn = 0, spawnDelay = T.spawnDelay
let seq = 0

function ts() { const d = Date.now() - (deadline - T.promiseTimeout); return (d / 1000).toFixed(2).padStart(6) }

async function readInfo() {
  const text = await readFile(FILE, "utf8").catch(() => undefined)
  if (text === undefined) return undefined
  try { return JSON.parse(text) } catch (e) { console.log(`[${ts()}] file corrupt:`, e.message); return undefined }
}

async function probe(info) {
  const signal = AbortSignal.timeout(T.requestTimeout)
  const url = new URL("/api/info", info.url)
  const headers = info.password === undefined ? undefined
    : { authorization: "Basic " + Buffer.from(`opencode:${info.password}`).toString("base64") }
  const t0 = Date.now()
  try {
    const response = await fetch(url, { headers, signal })
    const dt = Date.now() - t0
    let body
    try { body = response.status === 404 ? undefined : await response.json() } catch (e) { body = "<body-error:" + e.message + ">" }
    return { ok: true, status: response.status, body, dt }
  } catch (cause) {
    return { ok: false, aborted: signal.aborted, cause: String(cause && cause.cause ? cause.cause : cause), dt: Date.now() - t0 }
  }
}

function spawnContender() {
  const id = ++seq
  console.log(`[${ts()}] spawn contender #${id}: ${BIN} serve --service`)
  const child = spawn(BIN, ["serve", "--service"], {
    detached: true, stdio: ["ignore", "ignore", "pipe"], env: { ...process.env },
  })
  let stderr = "", exited = false
  child.stderr.on("data", (c) => { stderr = (stderr + c).slice(-4096) })
  child.once("exit", (code, sig) => {
    exited = true
    console.log(`[${ts()}] contender #${id} exit code=${code} sig=${sig} stderr=${JSON.stringify(stderr.slice(-500))}`)
  })
  child.once("error", (e) => console.log(`[${ts()}] contender #${id} spawn error:`, e.message))
  child.unref()
  return { child, id, isExited: () => exited }
}

const results = []
while (Date.now() < deadline) {
  const info = await readInfo()
  if (info !== undefined) {
    const r = await probe(info)
    results.push(r)
    console.log(`[${ts()}] probe ${info.url} (pid ${info.pid}, v${info.version}): ` +
      (r.ok ? `status=${r.status} dt=${r.dt}ms body=${JSON.stringify(r.body).slice(0, 200)}`
            : `FAIL dt=${r.dt}ms aborted=${r.aborted} cause=${r.cause.slice(0, 200)}`))
    if (r.ok && r.status >= 200 && r.status < 500 && r.body && r.body.pid === info.pid) {
      console.log(`[${ts()}] READY: would return ${info.url}`)
      console.log("[repro] SUCCESS in", ts(), "s")
      printSummary(results)
      process.exit(0)
    }
  }
  const finished = [...contenders].filter((c) => c.isExited())
  finished.forEach((c) => contenders.delete(c))
  if (contenders.size < 2 && Date.now() - lastSpawn >= spawnDelay) {
    contenders.add(spawnContender())
    lastSpawn = Date.now()
  }
  await new Promise((r) => setTimeout(r, 500)) // coarser than 25ms to keep log readable
}
console.log(`[${ts()}] TIMEOUT after ${T.promiseTimeout / 1000}s — same as production failure`)
printSummary(results)
process.exit(1)

function printSummary(results) {
  const fails = results.filter((r) => !r.ok)
  console.log(`[repro] probes: ${results.length} total, ${fails.length} failed` +
    (fails.length ? `, first-fail: ${fails[0].cause?.slice(0, 300)} (aborted=${fails[0].aborted})` : ""))
}
