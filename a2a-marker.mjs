#!/usr/bin/env node
// a2a-marker — extract & parse the A2A routing marker from an issue-comment body.
//
// Spec: research/A2A-ARCHITECTURE.md §3.1 (schema) + §3.5 (13 edge cases).
// Dependency-free (same rule as mcp-web/server.mjs): node >= 18, zero installs.
//
// Marker = YAML-inside-HTML-comment:
//   <!-- a2a:
//   to: researcher
//   from: coder
//   kind: request
//   turn: 3
//   -->
//   Human-readable body follows.
//
// Edge cases handled (numbering = §3.5):
//   1  empty marker -> null (no fields)
//   2  malformed YAML -> best-effort, warn on stderr, never throw
//   3  multiple markers -> FIRST wins (documented choice: the RFC-822-style
//      "first header block" reading; later markers are treated as quoted text)
//   4  nested comments -> INNERMOST a2a: opening wins (HTML comments end at the
//      first `-->`; an embedded `<!-- a2a:` inside that span is the real marker)
//   5  multi-line AND inline forms (`to: x from: y kind: z`, comma or space
//      separated) both parse
//   6  missing closing `-->` -> not a marker (scan continues for later ones)
//   7  whitespace variants: CRLF, tabs, leading/trailing space all identical
//   8  case-sensitive field names AND values (To: != to:; Request != request)
//   9  duplicate fields -> last value wins (YAML semantics)
//   10 unknown fields -> preserved in the returned object (router ignores)
//   11 body text before the marker -> marker still parsed
//   12 marker inside a fenced code block -> still parsed (parser is
//      code-fence-blind by design; callers must not emit markers in fences
//      unless they want them routed)
//   13 broadcast: `to: "*"` quoted scalar is canonical; unquoted `to: *` is
//      accepted WITH a warning (YAML would read bare * as an alias reference)
//
// Usage:
//   CLI:    node a2a-marker.mjs "$(cat comment.md)"   (or stdin: ... < file)
//           -> marker JSON on stdout (or literal null); warnings on stderr
//   Import: import { extractMarker } from "./a2a-marker.mjs";
//           extractMarker(body) -> Marker|null   (throws never)
//
// Output shape: flat object, string values (turn etc. stay strings —
// the gate step does its own numeric coercion; keeping everything strings
// preserves unknown-field fidelity).

const OPEN = "<!-- a2a:";
const OPEN_LEN = OPEN.length;
const CLOSE = "-->";

function extractMarker(body) {
  if (typeof body !== "string") return null;
  let idx = body.indexOf(OPEN);
  while (idx >= 0) {
    const end = body.indexOf(CLOSE, idx + OPEN_LEN);
    if (end < 0) {
      // Edge case 6: this opening never closes — skip it, keep scanning.
      idx = body.indexOf(OPEN, idx + 1);
      continue;
    }
    let candidate = body.slice(idx + OPEN_LEN, end);
    // Edge case 4: an embedded `<!-- a2a:` inside the span — innermost wins.
    const inner = candidate.lastIndexOf(OPEN);
    if (inner >= 0) candidate = candidate.slice(inner + OPEN_LEN);
    const parsed = parseMarkerYaml(candidate);
    if (parsed.fields.length > 0) return parsed.marker;
    // Edge case 1: zero fields parsed (empty marker) -> treat as null-ish and
    // continue scanning for a later well-formed marker (first VALID wins).
    idx = body.indexOf(OPEN, end + CLOSE.length);
  }
  return null;
}

// Remove every a2a marker block from a body (the gate's prompt-extraction
// step): from each `<!-- a2a:` opening to its NEXT `-->` (unclosed openings
// are left as-is — they are not markers per edge case 6). Mirrors the exact
// span semantics of extractMarker, so what is parsed is what gets stripped.
function stripMarkers(body) {
  if (typeof body !== "string") return "";
  let out = "";
  let cursor = 0;
  let idx = body.indexOf(OPEN);
  while (idx >= 0) {
    const end = body.indexOf(CLOSE, idx + OPEN_LEN);
    if (end < 0) break; // unclosed remainder: keep verbatim, stop
    out += body.slice(cursor, idx);
    cursor = end + CLOSE.length;
    idx = body.indexOf(OPEN, cursor);
  }
  out += body.slice(cursor);
  return out;
}

// Parse the flat YAML subset: one `key: value` per line, or inline
// `k: v k2: v2` / `k: v, k2: v2` on a single line. Never throws.
function parseMarkerYaml(text) {
  const warnings = [];
  const fields = [];
  // Edge case 7: normalize CRLF; split on any newline.
  const lines = String(text).replace(/\r\n?/g, "\n").split("\n");
  for (const rawLine of lines) {
    // A line with no `key:` pattern is prose inside the comment — skip.
    const keyRe = /(?:^|[\s,])([A-Za-z_][A-Za-z0-9_]*):(?=\s|$)/g;
    const tokens = [];
    let m;
    while ((m = keyRe.exec(rawLine)) !== null) tokens.push({ key: m[1], at: m.index + m[0].indexOf(m[1]) });
    if (tokens.length === 0) {
      if (rawLine.trim() !== "") warnings.push(`unparsed line: ${rawLine.trim().slice(0, 60)}`);
      continue;
    }
    for (let i = 0; i < tokens.length; i++) {
      const t = tokens[i];
      const valueStart = rawLine.indexOf(":", t.at + t.key.length) + 1;
      let value;
      if (i + 1 < tokens.length) {
        value = rawLine.slice(valueStart, tokens[i + 1].at);
      } else {
        value = rawLine.slice(valueStart);
      }
      value = value.trim();
      // Inline-form separators: trailing comma belongs to the separator.
      if (value.endsWith(",")) value = value.slice(0, -1).trim();
      // Quoted scalars (canonical broadcast form is `to: "*"`).
      if (
        (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
        (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
      ) {
        value = value.slice(1, -1);
      } else if (value === "*" && t.key === "to") {
        // Edge case 13: bare * is an illegal YAML alias at top level — accept
        // leniently with a warning, canonical form is the quoted "*".
        warnings.push('bare unquoted `to: *` accepted leniently; emit `to: "*"` instead');
      }
      // Edge case 8: field names are case-sensitive as-written; a `To:` stays
      // `To:` (unknown field, preserved, ignored by the router).
      fields.push({ key: t.key, value });
    }
  }
  // Edge case 9: last duplicate wins.
  const marker = {};
  for (const f of fields) marker[f.key] = f.value;
  for (const w of warnings) console.error(`a2a-marker: ${w}`);
  return { marker, fields, warnings };
}

// --- CLI -------------------------------------------------------------------
// Argv form: node a2a-marker.mjs "<body>"   Stdin form: echo <body> | node ...
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const strip = process.argv[2] === "--strip";
  const arg = strip ? process.argv[3] : process.argv[2];
  const body = typeof arg === "string" ? arg : (() => {
    try { return readFileSync(0, "utf8"); } catch { return ""; }
  })();
  if (strip) {
    process.stdout.write(stripMarkers(body));
  } else {
    const marker = extractMarker(body);
    process.stdout.write(marker === null ? "null\n" : JSON.stringify(marker) + "\n");
  }
}

export { extractMarker, stripMarkers };
