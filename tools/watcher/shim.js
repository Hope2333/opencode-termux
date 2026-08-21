#!/usr/bin/env node
/*
 * shim.js -- opencode-side event shim for the native watcher daemon
 *
 * Spawns tools/watcher/watcher (recursive inotify daemon), parses its
 * JSON Lines event stream, maps each event to a change callback, and
 * auto-restarts the watcher on crash (500ms backoff).
 *
 * Event stream (from watcher.c):
 *   {"t":"create|modify|delete|rename","p":"<path relative to root>"}
 *
 * Change callback (current implementation):
 *   1. Log a hook marker line with ISO timestamp + event type + path
 *      (the unique marker consumed by smoke tests / downstream tooling).
 *   2. Sentinel-touch fallback: touch <root>/.opencode-sentinel so that
 *      opencode's internal file watcher (when active, e.g. via
 *      OPENCODE_EXPERIMENTAL_FILEWATCHER=1) perceives the change and
 *      publishes file.watcher.updated on its event bus, which plugin
 *      `event` hooks receive (see docs/transplant.md "watcher 集成点").
 *      Sentinel events are ignored to avoid a touch->event->touch loop,
 *      and touches are rate-limited to one per 200ms.
 *
 * CLI (aligned with watcher):
 *   shim.js <root> [--debounce-ms N] [--max-depth D]
 *                 [--sentinel PATH] [--log FILE] [--watcher PATH] [--help]
 *
 * Env knobs:
 *   WATCHER_BIN   path to the watcher binary (default: ./watcher next to shim)
 *
 * Exit codes: 0 on clean shutdown (SIGINT/SIGTERM), 1 on usage error.
 */

"use strict"

const { spawn } = require("node:child_process")
const fs = require("node:fs")
const path = require("node:path")

const DEFAULT_DEBOUNCE_MS = 50
const DEFAULT_MAX_DEPTH = 32
const RESTART_BACKOFF_MS = 500
const SENTINEL_RATE_LIMIT_MS = 200
const SENTINEL_NAME = ".opencode-sentinel"

/* ---------------- arg parsing ---------------- */

function usage() {
  return [
    "usage: shim.js <root> [--debounce-ms N] [--max-depth D]",
    "                 [--sentinel PATH] [--log FILE] [--watcher PATH] [--help]",
    "",
    "opencode-side event shim: spawns the native watcher daemon, parses its",
    "JSON Lines event stream, maps events to change callbacks, and restarts",
    "the watcher on crash (500ms backoff).",
    "",
    "  root             directory to watch (required)",
    "  --debounce-ms N  passthrough to watcher (default 50)",
    "  --max-depth D    passthrough to watcher (default 32)",
    "  --sentinel PATH  sentinel file touched per event (default <root>/.opencode-sentinel)",
    "  --log FILE       write log to FILE instead of stdout",
    "  --watcher PATH   watcher binary path (default: ./watcher next to shim)",
    "  --help           show this help and exit",
    "",
    "Env: WATCHER_BIN overrides the watcher binary path.",
  ].join("\n")
}

function parseArgs(argv) {
  const opts = {
    root: null,
    debounceMs: DEFAULT_DEBOUNCE_MS,
    maxDepth: DEFAULT_MAX_DEPTH,
    sentinel: null,
    logFile: null,
    watcherBin: process.env.WATCHER_BIN || path.join(__dirname, "watcher"),
    help: false,
  }
  const passthrough = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    switch (a) {
      case "--help":
        opts.help = true
        break
      case "--debounce-ms":
        opts.debounceMs = Number(argv[++i])
        if (!Number.isFinite(opts.debounceMs) || opts.debounceMs < 0) {
          throw new Error(`invalid --debounce-ms: ${argv[i]}`)
        }
        passthrough.push(a, String(opts.debounceMs))
        break
      case "--max-depth":
        opts.maxDepth = Number(argv[++i])
        if (!Number.isFinite(opts.maxDepth) || opts.maxDepth < 1) {
          throw new Error(`invalid --max-depth: ${argv[i]}`)
        }
        passthrough.push(a, String(opts.maxDepth))
        break
      case "--sentinel":
        opts.sentinel = argv[++i]
        if (!opts.sentinel) throw new Error("--sentinel requires a path")
        break
      case "--log":
        opts.logFile = argv[++i]
        if (!opts.logFile) throw new Error("--log requires a path")
        break
      case "--watcher":
        opts.watcherBin = argv[++i]
        if (!opts.watcherBin) throw new Error("--watcher requires a path")
        break
      default:
        if (a.startsWith("-")) throw new Error(`unknown option: ${a}`)
        if (opts.root === null) opts.root = a
        else throw new Error(`unexpected positional argument: ${a}`)
    }
  }
  if (!opts.help && !opts.root) throw new Error("missing required <root> argument")
  opts.passthrough = passthrough
  return opts
}

/* ---------------- logging ---------------- */

function makeLogger(logFile) {
  const stream = logFile ? fs.createWriteStream(logFile, { flags: "a" }) : process.stdout
  return (line) => {
    stream.write(`${new Date().toISOString()} ${line}\n`)
  }
}

/* ---------------- sentinel fallback ---------------- */

function makeSentinelToucher(root, sentinelPath, log) {
  const sentinel = sentinelPath || path.join(root, SENTINEL_NAME)
  const sentinelRel = path.relative(root, sentinel)
  let lastTouch = 0
  return {
    path: sentinel,
    isSentinelEvent(p) {
      return p === sentinelRel || p === SENTINEL_NAME
    },
    touch() {
      const now = Date.now()
      if (now - lastTouch < SENTINEL_RATE_LIMIT_MS) return
      lastTouch = now
      try {
        fs.closeSync(fs.openSync(sentinel, "a"))
        log(`[sentinel] touched ${sentinel}`)
      } catch (err) {
        log(`[sentinel] touch failed: ${err.message}`)
      }
    },
  }
}

/* ---------------- event mapping ---------------- */

// watcher event type -> opencode file.watcher.updated event name
const EVENT_MAP = {
  create: "add",
  modify: "change",
  delete: "unlink",
  rename: "change", // rename carries destination; reload semantics
}

function parseEvent(line) {
  try {
    const evt = JSON.parse(line)
    if (typeof evt.t !== "string" || typeof evt.p !== "string") return null
    return { type: evt.t, path: evt.p }
  } catch {
    return null
  }
}

/* ---------------- watcher process management ---------------- */

function spawnWatcher(opts, log, onEvent) {
  const args = [opts.root, ...opts.passthrough]
  log(`[spawn] ${opts.watcherBin} ${args.join(" ")}`)
  const child = spawn(opts.watcherBin, args, { stdio: ["ignore", "pipe", "pipe"] })

  let buf = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    buf += chunk
    let nl
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim()
      buf = buf.slice(nl + 1)
      if (!line) continue
      const evt = parseEvent(line)
      if (evt) onEvent(evt)
      else log(`[parse] non-JSON line: ${line}`)
    }
  })

  // Never swallow watcher stderr: pass through to the log.
  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk) => {
    for (const line of chunk.split("\n")) {
      if (line.trim()) log(`[watcher-stderr] ${line}`)
    }
  })

  child.on("error", (err) => {
    log(`[error] watcher spawn failed: ${err.message}`)
  })

  return child
}

/* ---------------- main ---------------- */

function main() {
  let opts
  try {
    opts = parseArgs(process.argv.slice(2))
  } catch (err) {
    process.stderr.write(`shim.js: ${err.message}\n\n${usage()}\n`)
    process.exit(1)
  }
  if (opts.help) {
    process.stdout.write(`${usage()}\n`)
    process.exit(0)
  }

  const log = makeLogger(opts.logFile)
  const sentinel = makeSentinelToucher(opts.root, opts.sentinel, log)
  // Ignore the shim's own log file when it lives inside the watched root,
  // otherwise every log write re-triggers a modify event (feedback loop).
  const logRel = opts.logFile ? path.relative(opts.root, opts.logFile) : null
  let shuttingDown = false
  let restarts = 0

  const onEvent = (evt) => {
    if (logRel && (evt.path === logRel || evt.path === path.basename(logRel))) return
    const mapped = EVENT_MAP[evt.type] || evt.type
    // Unique hook marker: timestamp (added by logger) + type + path.
    log(`[hook] event=${mapped} watcher_type=${evt.type} path=${evt.path}`)
    if (!sentinel.isSentinelEvent(evt.path)) {
      sentinel.touch()
    }
  }

  let restartTimer = null

  const start = () => {
    const proc = spawnWatcher(opts, log, onEvent)
    proc.on("exit", (code, signal) => {
      if (shuttingDown) {
        log(`[exit] watcher exited (code=${code} signal=${signal}); shutting down, no restart`)
        return
      }
      restarts += 1
      log(`[restart] watcher exited (code=${code} signal=${signal}); restart #${restarts} in ${RESTART_BACKOFF_MS}ms`)
      // Track the restarted process: write it back to the outer `child`
      // so a later shutdown() kills the live watcher, not the dead one.
      restartTimer = setTimeout(() => {
        child = start()
      }, RESTART_BACKOFF_MS)
    })
    return proc
  }

  let child = start()

  const shutdown = (sig) => {
    if (shuttingDown) return
    shuttingDown = true
    // Cancel any pending auto-restart, otherwise a SIGTERM landing inside
    // the backoff window would spawn a fresh watcher right before exit(0).
    if (restartTimer !== null) {
      clearTimeout(restartTimer)
      restartTimer = null
    }
    log(`[shutdown] received ${sig}; terminating watcher`)
    child.kill("SIGTERM")
    // Give the watcher a moment to flush, then hard-kill and exit.
    setTimeout(() => {
      try {
        child.kill("SIGKILL")
      } catch {
        /* already gone */
      }
      process.exit(0)
    }, 300)
  }

  process.on("SIGINT", () => shutdown("SIGINT"))
  process.on("SIGTERM", () => shutdown("SIGTERM"))
}

main()