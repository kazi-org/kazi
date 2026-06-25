#!/usr/bin/env bash
#
# mcp_release_smoke.sh (T33.4, ADR-0044) -- release-parity MCP smoke.
#
# Drives the INSTALLED Burrito binary (NOT `mix`) as an MCP stdio server: starts
# `<bin> mcp`, performs the JSON-RPC handshake, lists the tools, and calls
# kazi_status -- then asserts the binary actually answered. ADR-0044 names this
# launch-parity smoke (start via `kazi mcp`, list tools, call `kazi_status`)
# sufficient to verify the installed release ships a working MCP server path.
#
# This runs as a RELEASE-JOB step BEFORE the built binary is published, so a
# non-zero exit BLOCKS the release: a binary that cannot serve `kazi mcp` never
# becomes a GitHub Release asset.
#
# Usage:
#   .github/scripts/mcp_release_smoke.sh <path-to-kazi-binary>
#
# Requires: jq (preinstalled on the GitHub macOS/Ubuntu runners; the arm64
# container job installs it explicitly).
set -euo pipefail

bin="${1:?usage: mcp_release_smoke.sh <path-to-kazi-binary>}"
[ -x "$bin" ] || {
  echo "smoke: binary not found or not executable: $bin" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "smoke: jq is required but not installed" >&2
  exit 1
}

# A bogus ref the read-model resolves to a structured not_found result -- enough
# to prove the bundled SQLite read-model booted and the tool dispatched (a
# degraded/missing read-model would not return a clean status payload). The
# server reads ONE line-delimited JSON-RPC request per line and stops at EOF.
requests="$(
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"release-smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"kazi_status","arguments":{"ref":"release-smoke-probe"}}}'
)"

# Feed all requests on stdin; EOF ends the serve loop. Capture stdout only --
# the server redirects every log handler to stderr so stdout carries ONLY the
# JSON-RPC stream.
out="$(printf '%s\n' "$requests" | "$bin" mcp)" || {
  echo "smoke: \`$bin mcp\` exited non-zero" >&2
  exit 1
}

echo "--- kazi mcp stdout ---" >&2
printf '%s\n' "$out" >&2
echo "-----------------------" >&2

# Every emitted line must be a JSON object (the MCP stdio framing: no human
# prose may leak onto the transport).
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line" | jq -e 'type == "object"' >/dev/null || {
    echo "smoke: a non-JSON line leaked onto the MCP transport: $line" >&2
    exit 1
  }
done <<<"$out"

# Pull each response by its request id.
get() { printf '%s\n' "$out" | jq -c "select(.id == $1)" | head -1; }
init_resp="$(get 1)"
tools_resp="$(get 2)"
status_resp="$(get 3)"

[ -n "$init_resp" ] || {
  echo "smoke: no initialize response" >&2
  exit 1
}
[ -n "$tools_resp" ] || {
  echo "smoke: no tools/list response" >&2
  exit 1
}
[ -n "$status_resp" ] || {
  echo "smoke: no tools/call response" >&2
  exit 1
}

# initialize must advertise this server (serverInfo.name == "kazi").
printf '%s\n' "$init_resp" | jq -e '.result.serverInfo.name == "kazi"' >/dev/null || {
  echo "smoke: initialize did not return serverInfo.name == kazi" >&2
  exit 1
}

# tools/list must advertise kazi_status (the tool the smoke then calls).
printf '%s\n' "$tools_resp" | jq -e '[.result.tools[].name] | index("kazi_status") != null' >/dev/null || {
  echo "smoke: tools/list did not advertise kazi_status" >&2
  exit 1
}

# kazi_status must answer with a structured status payload (kind + schema_version),
# not a protocol error -- proving the installed binary served a real tool call
# against the bundled read-model.
printf '%s\n' "$status_resp" | jq -e '.result.isError == false' >/dev/null || {
  echo "smoke: kazi_status returned isError or a protocol error" >&2
  exit 1
}
printf '%s\n' "$status_resp" | jq -e '.result.structuredContent | has("kind") and has("schema_version")' >/dev/null || {
  echo "smoke: kazi_status result is not a status payload" >&2
  exit 1
}

echo "smoke: PASS -- installed binary served \`kazi mcp\` (tools/list advertised kazi_status; kazi_status answered)" >&2
