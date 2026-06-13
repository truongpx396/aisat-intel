# Page Override: Agents & Long-Horizon Tasks

> Overrides `../MASTER.md` for the Agents screen. Covers User Story 7
> (FR-025…FR-028) — optional local agents and durable long-horizon tasks.

## Purpose
Register and manage optional **local agents** (scoped to a user + workspace with
revocable device credentials), and monitor **long-horizon tasks** that survive worker
interruption, can be cancelled, and are bounded by a hard per-task cost cap. The whole
screen must communicate that agents are *additive* — every core feature works without one.

## Layout
- App shell; active nav = **Agents**.
- "Additive" notice at top: "All core features work without an agent. Agents only add
  long-horizon, multi-step tasks."
- Two zones:
  1. **Registered devices** — list of local agents with status, mode, and revoke.
  2. **Long-horizon tasks** — active + historical task list with checkpoint/progress,
     spend vs cap, and cancel.

## Key components
- **Device/agent card**: device name, scope (`user@workspace`), connection status
  (`connected` green / `offline` muted), **routing mode** badge — `server-routed`
  (metered+audited, default) vs `bring-your-own-key` (amber warning: bypasses server
  token metering; admin-disableable). **Revoke credentials** action.
- **Register agent** flow: generates a one-time device credential; if the user picks
  BYOK mode, require an explicit acceptance of the metering/moderation gap (FR-026).
- **Task row**: title, status pill (`running`/`checkpointed`/`resumed`/`cancelled`/
  `completed`/`halted-cost-cap`), a **step/checkpoint** indicator, **spend meter**
  (credits used vs per-task cap, turns red near the cap), and **Cancel**.
- **Resume note**: visibly show when a task auto-resumed from its last checkpoint after
  a worker interruption (FR-028) and when a stale worker was re-queued.
- **Cost-cap halt**: a distinct halted state explaining the task stopped at its per-task
  cap independent of the daily budget (US7 scenario 5), with an option to raise the cap.

## States to show
- One connected server-routed agent + one BYOK agent (with the warning).
- A running task with checkpoint progress and spend meter.
- A task halted at its cost cap (danger), and one resumed-after-interruption (info).

## Don'ts
- Don't present agents as required for core features.
- Don't hide the BYOK metering/moderation tradeoff.
- Don't trust agent-claimed scope — UI reflects server-validated scope only (FR-027).
