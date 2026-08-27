# cc-gha-public-executor

**Public-compute executor for the private [`cc-gha-exploration`](https://github.com/xfnwfpho1/cc-gha-exploration) track.**
GitHub-hosted runners are **free and unlimited on public repos**; private repos
burn the plan's minute quota (~583 of 2,000 free-plan minutes in 4 days of
experimentation). This repo moves non-A2A workloads to public compute while all
content, results, and the agent conversation surface stay private.

## What lives here (and what must NEVER live here)

| Allowed here | Must stay in the private repo |
|---|---|
| Workflow orchestration (dispatch/schedule drivers) | Issue threads (the A2A transport — human + agent chatter) |
| Compute-heavy, content-insensitive one-shot tasks | Code under review, research docs, session transcripts |
| The stall scanner (numbers-only logging) | Secrets-bearing content beyond the two repo secrets |
| The a2a marker parser copy (`a2a-marker.mjs`) | Agent session state (`agent-sessions` branch) |

## The two patterns proven here

### 1. Public executor, private everything else (non-A2A tasks)

```
human/agent → workflow_dispatch THIS repo (inputs = pointers, never secrets)
             → runner clones the PRIVATE repo using GH_PAT_PRIVATE
             → does the heavy lifting (CC agent turn, long job — free minutes)
             → pushes results / posts comments to the PRIVATE repo via PAT
             → public log contains NO task content (log hygiene, see below)
```

Secrets on a public repo: **encrypted at rest, never readable via any API,
never visible to other users, masked automatically in all logs**. They are
injected only into runs of THIS repo, only for triggers that require write
access to fire (see the security model). Fork PRs never receive secrets
(GitHub-enforced for `pull_request` events).

### 2. External scheduler for the private swarm sweep

The private repo's `schedule` trigger has never fired (zero `event=schedule`
runs across 6+ missed ticks and two cron re-registrations). `scheduler.yml`
replaces it: cron on THIS repo (public, free) → smart scan of the private
repo's open issues via PAT → dispatch the private lead sweep **only when a
stall is actually detected**. Private quota is spent on real work, not
monitoring cadence.

## Security model (READ BEFORE ADDING ANY TRIGGER)

This is a **public** repo. Every workflow run, its logs, and its artifacts are
world-readable. Rules:

1. **Triggers: `workflow_dispatch` + `schedule` only.** Both require write
   access (or an internal timer) to fire. NEVER add:
   - `pull_request_target` — checks out attacker code WITH secrets. Classic
     pwn-request vector.
   - `pull_request` — safe (no secrets for forks) but pointless here; avoid.
   - `issue_comment` — ANY GitHub user can comment on a public repo; the
     write-access gate would hold, but why expose the surface.
   - `workflow_run` — fires after other workflows complete; can indirectly
     chain from fork activity. Avoid.
2. **Log hygiene — assume every logged line is public.** Issue *numbers* are
   fine; titles, bodies, comment text, private file contents, and usernames
   are not. Never `cat` private-repo files into logs; pass results via the
   authenticated API only.
3. **Secrets are masked, not permissioned.** GitHub masks registered secret
   values in logs as a safety net — it is not an access-control system. A
   workflow step that exfiltrates a secret over the network still can.
   Every script in this repo is reviewed with that in mind.
4. **Inputs are pointers, never payloads.** Dispatch inputs are visible in the
   run UI — pass issue/PR numbers, not task text, never credentials.
5. **`permissions: contents: none`** on every workflow; cross-repo access
   goes through `GH_PAT_PRIVATE` explicitly.

## Secrets

| Name | Purpose |
|---|---|
| `GH_PAT_PRIVATE` | PAT with `repo` scope — private-repo read + dispatch + push-back |
| `SMOKE_TEST_SECRET` | A dummy value used by `smoke.yml` to demonstrate log masking |

## Provenance

- `a2a-marker.mjs` is copied verbatim from the private repo's
  `mcp-web/a2a-marker.mjs` (27/27 unit tests there). If the private parser
  changes, re-copy — the scheduler's correctness depends on marker parity.
