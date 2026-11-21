import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const files = args.length
  ? args.map((a) => path.resolve(process.cwd(), a))
  : fs.readdirSync(path.join(here, "unit"))
      .filter((f) => f.endsWith(".bats"))
      .sort()
      .map((f) => path.join(here, "unit", f));

const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

function parseTests(text) {
  const lines = text.split("\n");
  const tests = [];
  const preamble = [];
  let current = null;
  let heredoc = null;
  for (const line of lines) {
    if (!current) {
      const m = /^@test\s+"([^"]+)"\s+\{/.exec(line);
      if (m) current = { name: m[1], body: [] };
      else preamble.push(line);
      continue;
    }
    if (heredoc) {
      current.body.push(line);
      if (line.trim() === heredoc) heredoc = null;
      continue;
    }
    const hm = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/.exec(line);
    if (hm) heredoc = hm[1];
    if (/^}\s*$/.test(line)) {
      tests.push({ name: current.name, body: current.body.join("\n") });
      current = null;
      continue;
    }
    current.body.push(line);
  }
  if (current) tests.push({ name: current.name, body: current.body.join("\n") });
  return { preamble: preamble.join("\n"), tests };
}

const helpers = [
  "mktemp() {",
  "  local args=() a",
  "  for a in \"$@\"; do",
  "    if [[ \"$a\" == /tmp/* ]]; then",
  "      args+=(\"${TMPDIR%/}/${a#/tmp/}\")",
  "    else",
  "      args+=(\"$a\")",
  "    fi",
  "  done",
  "  command mktemp \"${args[@]}\"",
  "}",
  "load() {",
  "  local f=\"$1\"",
  "  [[ \"$f\" == *.bash ]] || f=\"$f.bash\"",
  "  if [[ \"$f\" = /* ]]; then",
  "    source \"$f\"",
  "  else",
  "    source \"$BATS_TEST_DIRNAME/$f\"",
  "  fi",
  "}",
  "run() {",
  "  set +e",
  "  output=$(\"$@\" 2>&1)",
  "  status=$?",
  "  set -e",
  "  lines=()",
  "  if [[ -n \"$output\" ]]; then",
  "    mapfile -t lines <<< \"$output\"",
  "  fi",
  "  return 0",
  "}",
  "skip() {",
  "  printf 'SKIP %s\\n' \"$*\"",
  "  exit 77",
  "}",
].join("\n");

const blocks = [];
for (const file of files) {
  const text = fs.readFileSync(file, "utf8");
  const { preamble, tests } = parseTests(text);
  const dir = path.dirname(file);
  const label = path.relative(path.dirname(here), file);
  const names = tests.map((t) => `  names+=(${q(t.name)})`).join("\n");
  const fns = tests
    .map((t, i) => `t${i}() {\n${t.body}\n}`)
    .join("\n");
  blocks.push(`
(
  set -e
  cd ${q(dir)}
  export BATS_TEST_DIRNAME=${q(dir)}
${helpers}
${preamble}
${fns}
  names=()
${names}
  BATS_TEST_TMPDIR="$(mktemp -d "\${TMPDIR}/ot.XXXXXX")"
  export BATS_TEST_TMPDIR
  file_rc=0
  for i in "\${!names[@]}"; do
    testtmp="$BATS_TEST_TMPDIR/$i"
    mkdir -p "$testtmp"
    set +e
    (
      set -e
      export BATS_TEST_TMPDIR="$testtmp"
      trap 'rc=$?; set +e; declare -F teardown >/dev/null && teardown; exit $rc' EXIT
      if declare -F setup >/dev/null; then setup; fi
      "t$i"
    ) >"$testtmp/out.log" 2>&1
    rc=$?
    set -e
    label="\${names[$i]}"
    if [[ $rc -eq 0 ]]; then
      printf 'ok %s:%s %s\\n' ${q(label)} "$((i + 1))" "$label"
    elif [[ $rc -eq 77 ]]; then
      printf -- '- %s:%s %s (skipped)\\n' ${q(label)} "$((i + 1))" "$label"
    else
      printf 'x %s:%s %s (exit %s)\\n' ${q(label)} "$((i + 1))" "$label" "$rc"
      cat "$testtmp/out.log"
      file_rc=1
    fi
  done
  rm -rf "$BATS_TEST_TMPDIR"
  exit $file_rc
)
if [[ $? -ne 0 ]]; then overall_rc=1; fi
`);
}

const script = `#!/data/data/com.termux/files/usr/bin/env bash
set -uo pipefail
export TMPDIR=${q(os.tmpdir())}
overall_rc=0
${blocks.join("\n")}
exit $overall_rc
`;

const result = spawnSync("bash", ["-c", script], {
  encoding: "utf8",
  env: { ...process.env, TMPDIR: os.tmpdir() },
  maxBuffer: 32 * 1024 * 1024,
});
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
