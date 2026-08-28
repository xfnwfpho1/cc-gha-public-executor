#!/usr/bin/env bash
# board-sync — mirror the swarm's per-issue state onto the Projects v2 board.
#
# Part of Task 36 (channel strategy + GH-seam glue + robustness layers).
# Runs on the PUBLIC executor inside the scheduler job (free minutes).
#
# INPUT: a jsonl state file, one line per ACTIVE (marker-carrying) issue:
#   {"issue": 6, "status": "In Progress|Stalled|Idle|Failed", "agent": "coder"}
#
# BOARD MODEL (A2A-CHANNEL-STRATEGY.md): the board is the STATE layer and the
# operator's single dashboard — never a wake surface (projects_v2_item cannot
# trigger workflows; proven run 33142384110). One item per agent-active issue;
# Status mirrors the conversation state; Agent = who is on the hook. Issues
# that close (or lose their markers) are REMOVED — the board shows live work.
#
# CAPABILITY / GRACEFUL DEGRADATION: Projects v2 GraphQL requires a PAT with
# `project` scope. GH_PAT_PRIVATE was audited 2026-08-28 to carry repo+workflow
# only → this step logs a skip and exits 0 (the scheduler NEVER breaks because
# of the board). It lights up the moment the operator adds a project-scoped
# BOARD_PAT secret (or expands GH_PAT_PRIVATE). Runbook: DIAGNOSTICS.md.
#
# SELF-INSTALLING: if the board (or a field) is missing, or a field's option
# set doesn't match the required set, it is created/recreated (recreating a
# single-select drops its values — acceptable for a mirror, never a source).
#
# LOG HYGIENE (public repo — every line is world-readable):
#   - issue NUMBERS, statuses, agent ids, and counts ONLY
#   - never titles/bodies/comment text (they never enter this script)
#   - GraphQL error TYPES may be logged (e.g. INSUFFICIENT_SCOPES), never data
set -euo pipefail

STATE_FILE=${1:?usage: board-sync.sh <state-file.jsonl>}
PRIVATE_REPO=${PRIVATE_REPO:?}
ROSTER=${ROSTER:?}                  # comma-separated agent ids (registry-driven)
BOARD_NUMBER=${BOARD_NUMBER:-1}     # the "A2A Swarm Board" user project
BOARD_TITLE=${BOARD_TITLE:-A2A Swarm Board}
# BOARD_PAT (project-scoped) overrides GH_PAT_PRIVATE when present.
TOKEN=${BOARD_PAT:-${GH_PAT_PRIVATE:?need GH_PAT_PRIVATE or BOARD_PAT}}

GQL() { # GQL <payload-json> → GraphQL response on stdout; empty string on transport failure
  local RES
  RES=$(printf '%s' "$1" | gh api graphql --input - 2>/dev/null || true)
  printf '%s' "${RES:-}"
}

# jq-with-fallback: never let a malformed/empty response crash the sync (jq's
# null-iteration errors exit 5 — and `set -e` is SUPPRESSED inside functions
# invoked via command substitution, a verified bash trap — so every parse
# needs an explicit fallback).
jqf() { # jqf <filter> [jq args...] — reads stdin
  local FILTER=$1; shift
  jq -r "$FILTER" "$@" 2>/dev/null || echo ""
}

# ---------- 0. capability gate (the graceful-skip contract) ----------
PROBE=$(GQL "{\"query\": \"query { user(login: \\\"${PRIVATE_REPO%%/*}\\\") { projectV2(number: ${BOARD_NUMBER}) { id title } } }\"}")
if [ -z "$PROBE" ]; then
  echo "board sync: SKIPPED — board probe returned nothing (transport). Scheduler continues normally."
  exit 0
fi
if printf '%s' "$PROBE" | jq -e '.errors[]? | select(.type=="INSUFFICIENT_SCOPES")' >/dev/null 2>&1; then
  echo "board sync: SKIPPED — token lacks the project scope (audited state; add BOARD_PAT to activate). Scheduler continues normally."
  exit 0
fi
PROJECT_ID=$(printf '%s' "$PROBE" | jq -r '.data.user.projectV2.id // empty' 2>/dev/null || true)
if [ -z "$PROJECT_ID" ]; then
  echo "board sync: board #${BOARD_NUMBER} not found — creating it (self-install)."
  VIEWER=$(GQL '{"query": "query { viewer { id } }"}')
  OWNER_ID=$(printf '%s' "$VIEWER" | jq -r '.data.viewer.id // empty' 2>/dev/null || true)
  if [ -z "$OWNER_ID" ]; then echo "board sync: viewer id unavailable — skipping this cycle." >&2; exit 0; fi
  CREATE=$(GQL "{\"query\": \"mutation(\$o: ID!, \$t: String!) { createProjectV2(input: {ownerId: \$o, title: \$t}) { projectV2 { id } } }\", \"variables\": {\"o\": \"${OWNER_ID}\", \"t\": \"${BOARD_TITLE}\"}}")
  PROJECT_ID=$(printf '%s' "$CREATE" | jq -r '.data.createProjectV2.projectV2.id // empty' 2>/dev/null || true)
  [ -n "$PROJECT_ID" ] || { echo "board sync: createProjectV2 failed — skipping this cycle." >&2; exit 0; }
fi

# ---------- 1. ensure the Status + Agent fields with the right options ----
REQUIRED_STATUS="In Progress,Stalled,Idle,Failed"
AGENT_OPTIONS="${ROSTER},unassigned"

FIELDS_RES=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options(first: 30) { nodes { name } } } } } } } }\"}")

ensure_field() { # ensure_field <name> <comma-separated options> → field id on STDOUT
  local NAME=$1 OPTIONS=$2
  local FID HAVE
  # NOTE: this function's stdout is a RETURN VALUE (captured by the caller) —
  # all diagnostics MUST go to stderr or they corrupt the returned id.
  # (Verified live in fixture tests: a stray message on stdout BECOMES the
  # field id; the failing mutations then silently no-op — the worst failure
  # mode: looks healthy, does nothing.)
  FID=$(printf '%s' "$FIELDS_RES" | jq -r --arg n "$NAME" '[.data.node.fields.nodes[] | select(.name == $n)][0].id // empty' 2>/dev/null || true)
  if [ -n "$FID" ]; then
    # Option-set drift → recreate (single-select options can only be set at
    # field creation via public GraphQL — there is no add-option mutation).
    HAVE=$(printf '%s' "$FIELDS_RES" | jq -r --arg n "$NAME" '[.data.node.fields.nodes[] | select(.name == $n)][0].options.nodes[].name' 2>/dev/null | sort | paste -sd, || true)
    if [ "$HAVE" != "$(printf '%s' "$OPTIONS" | tr ',' '\n' | sed '/^$/d' | sort | paste -sd,)" ]; then
      echo "board sync: field '${NAME}' option drift — recreating field (values reset)." >&2
      GQL "{\"query\": \"mutation(\$p: ID!, \$f: ID!) { deleteProjectV2Field(input: {projectId: \$p, fieldId: \$f}) { deletedFieldId } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"f\": \"${FID}\"}}" >/dev/null
      FID=""
    fi
  fi
  if [ -z "$FID" ]; then
    local OPTS CREATED
    OPTS=$(printf '%s' "$OPTIONS" | jq -R -r 'split(",") | map(select(length > 0) | {name: .}) | tojson')
    CREATED=$(GQL "{\"query\": \"mutation(\$p: ID!, \$n: String!, \$o: [ProjectV2SingleSelectOptionInput!]!) { createProjectV2Field(input: {projectId: \$p, name: \$n, dataType: SINGLE_SELECT, singleSelectOptions: \$o}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"n\": \"${NAME}\", \"o\": ${OPTS}}}")
    FID=$(printf '%s' "$CREATED" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null || true)
    [ -n "$FID" ] || { echo "board sync: could not ensure field '${NAME}' — skipping this cycle." >&2; exit 0; }
  fi
  printf '%s' "$FID"
}

STATUS_FIELD=$(ensure_field "Status" "$REQUIRED_STATUS")
AGENT_FIELD=$(ensure_field "Agent" "$AGENT_OPTIONS")

# ---------- 2. current board items + option ids ---------------------------
ITEMS=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { items(first: 100) { nodes { id content { ... on Issue { number } } fieldValues(first: 10) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2Field { name } } } } } } } } } }\"}")
OPTIONS_RES=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options(first: 30) { nodes { id name } } } } } } } }\"}")
if [ -z "$ITEMS" ] || [ -z "$OPTIONS_RES" ]; then
  echo "board sync: item/option query failed (transport) — skipping this cycle." >&2
  exit 0
fi

opt_id() { # opt_id <field name> <option name> → option id ("" on any parse failure)
  # Hardened: a malformed/empty OPTIONS_RES must degrade to "no update",
  # never crash the scheduler step (verified live: the unhardened form exits 5
  # and takes the whole job down — the exact anti-contract failure).
  printf '%s' "$OPTIONS_RES" | jq -r --arg f "$1" --arg o "$2" \
    '[.data.node.fields.nodes[] | select(.name == $f)][0].options.nodes[] | select(.name == $o) | .id' 2>/dev/null | head -1 || true
}

# ---------- 3. diff state vs board ----------------------------------------
ADDED=0; UPDATED=0; REMOVED=0; KEPT=0
declare -A BOARD_ITEM_ID BOARD_STATUS BOARD_AGENT
while IFS=$'\t' read -r ITEM_ID INUM CST CAG; do
  BOARD_ITEM_ID[$INUM]=$ITEM_ID
  BOARD_STATUS[$INUM]=$CST
  BOARD_AGENT[$INUM]=$CAG
done < <(printf '%s' "$ITEMS" | jq -r '.data.node.items.nodes[]
  | [.id, (.content.number // 0),
     ([.fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // ""),
     ([.fieldValues.nodes[] | select(.field.name == "Agent") | .name][0] // "")] | @tsv' 2>/dev/null || true)

while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  NUM=$(printf '%s' "$LINE" | jq -r '.issue // empty' 2>/dev/null || true)
  [ -n "$NUM" ] || continue   # malformed state line — skip, never crash the step
  WANT_STATUS=$(printf '%s' "$LINE" | jq -r '.status // empty' 2>/dev/null || true)
  WANT_AGENT=$(printf '%s' "$LINE" | jq -r '.agent // "unassigned"' 2>/dev/null || true)
  ITEM_ID=${BOARD_ITEM_ID[$NUM]:-}
  if [ -z "$ITEM_ID" ]; then
    # new active issue → add the real issue as a board item
    NODE_ID=$(gh api "repos/${PRIVATE_REPO}/issues/${NUM}" --jq .node_id 2>/dev/null || echo "")
    if [ -z "$NODE_ID" ]; then echo "board sync: issue #${NUM} not fetchable — skipping."; continue; fi
    ADDED=$((ADDED+1))
    ITEM_ID=$(GQL "{\"query\": \"mutation(\$p: ID!, \$c: ID!) { addProjectV2ItemById(input: {projectId: \$p, contentId: \$c}) { item { id } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"c\": \"${NODE_ID}\"}}" | jq -r '.data.addProjectV2ItemById.item.id // empty' 2>/dev/null || true)
    if [ -z "$ITEM_ID" ]; then echo "board sync: addProjectV2ItemById failed for issue #${NUM} — skipping it." >&2; continue; fi
    BOARD_ITEM_ID[$NUM]=$ITEM_ID; BOARD_STATUS[$NUM]=""; BOARD_AGENT[$NUM]=""
    echo "board sync: + issue #${NUM} (${WANT_STATUS}, ${WANT_AGENT})"
  fi
  # Status + Agent field updates only on change
  for FLD in Status Agent; do
    if [ "$FLD" = "Status" ]; then WANT=$WANT_STATUS; CUR=${BOARD_STATUS[$NUM]}; FID=$STATUS_FIELD
    else WANT=$WANT_AGENT; CUR=${BOARD_AGENT[$NUM]}; FID=$AGENT_FIELD; fi
    if [ -n "$WANT" ] && [ "$WANT" != "$CUR" ]; then
      OID=$(opt_id "$FLD" "$WANT")
      if [ -n "$OID" ]; then
        GQL "{\"query\": \"mutation(\$p: ID!, \$i: ID!, \$f: ID!, \$v: String!) { updateProjectV2ItemFieldValue(input: {projectId: \$p, itemId: \$i, fieldId: \$f, value: {singleSelectOptionId: \$v}}) { projectV2Item { id } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"i\": \"${ITEM_ID}\", \"f\": \"${FID}\", \"v\": \"${OID}\"}}" >/dev/null
        UPDATED=$((UPDATED+1))
      fi
    fi
  done
  KEPT=$((KEPT+1))
done < "$STATE_FILE"

# remove items whose issue left the active set (closed / no markers anymore)
STATE_NUMS=$(jq -r '.issue' "$STATE_FILE" 2>/dev/null | sort -n | paste -sd' ')
for INUM in "${!BOARD_ITEM_ID[@]}"; do
  if ! printf ' %s ' "$STATE_NUMS" | grep -q " ${INUM} "; then
    GQL "{\"query\": \"mutation(\$p: ID!, \$i: ID!) { deleteProjectV2Item(input: {projectId: \$p, itemId: \$i}) { deletedItemId } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"i\": \"${BOARD_ITEM_ID[$INUM]}\"}}" >/dev/null
    REMOVED=$((REMOVED+1))
    echo "board sync: - issue #${INUM} (no longer active)"
  fi
done

echo "board sync: ${KEPT} active issues (+${ADDED} added, ${UPDATED} field updates, -${REMOVED} removed)"
