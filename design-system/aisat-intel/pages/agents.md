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
- **Task row**: title, status pill (`running`/`checkpointed`/`resumed`/`awaiting-approval`/
  `cancelled`/`completed`/`halted-cost-cap`), a **step/checkpoint** indicator, **spend meter**
  (credits used vs per-task cap, turns red near the cap), and **Cancel**. A row in
  `awaiting-approval` (amber) exposes the **approval card** inline (see below) and shows
  "no credits spent while paused".
- **Resume note**: visibly show when a task auto-resumed from its last checkpoint after
  a worker interruption (FR-028) and when a stale worker was re-queued.
- **Cost-cap halt**: a distinct halted state explaining the task stopped at its per-task
  cap independent of the daily budget (US7 scenario 5), with an option to raise the cap.

## Agent actions & human-in-the-loop (Phase 1, FR-041)
Phase 1 gives the agent two **action** tools beyond read-only retrieval, each gated by the
human-in-the-loop approval card (MASTER "Approval card"); both run only inside a durable
long-horizon run, so the gate can pause and resume it.
- **`web_search` (user + admin roles)**: when a task needs fresh external info, the run
  pauses (`awaiting-approval`) and the approval card shows the **intended query + target
  host** for a **per-fetch** confirm. Approve → the fetch runs (SSRF-guarded `web_distill`);
  Reject → the run continues without web. No fetch and no spend happen before approval.
- **`edit_note` (access-bounded write)**: the agent proposes an edit to an **existing**
  note; the approval card shows a **red/green diff** of the proposed `body`, the acting
  agent's effective clearance (`min(agent, owner)`), and the target note. Approve → the note
  updates + re-indexes; Reject → unchanged. The UI must reflect the server bounds: the agent
  can edit only the owner's own personal notes or shared workspace notes ≤ its clearance, can
  never raise the note's clearance above its source floor, and **cannot create** a note — an
  attempt outside scope shows the denial reason (`not_found` / `envelope_widens`), never a
  silent success. The Library's agent-authored view links here.
- **Both are off by default per role** — enabled from the Admin agent-policy controls
  (`can_write` / `write_ops`, allowed-tools). Surface the enablement state on the device card.

## States to show
- One connected server-routed agent + one BYOK agent (with the warning).
- A running task with checkpoint progress and spend meter.
- A task halted at its cost cap (danger), and one resumed-after-interruption (info).
- A task **awaiting approval** (amber) with the approval card open — one showing a
  `web_search` confirm, one showing a `note_edit` diff — so both gated actions are legible.

## Don'ts
- Don't say "run on agent" for a long-horizon task. It runs on the AISAT worker under that
  agent's identity, and the wrong verb sends people debugging their laptop.
- Don't present `connected` as health. A binary heartbeat hides an agent that is connected
  and erroring or being denied on every call.
- Don't hide denials. They are the difference between "this agent is working" and "this
  agent is silently blocked", and they are invisible in every other view.
- Don't let an own-key agent's missing LLM metrics read as zero or as an error. Absent
  observability must be labelled as absent.
- Don't add a third routing option for vendor-hosted agents. If a choice changes no behaviour,
  it is a note, not a mode.
- Don't leave "server-routed" anywhere. One vocabulary, every surface, and the confirm step
  reads the actual selection.
- Don't frame the own-key option as a risk to be acknowledged. It is one of two paths you
  deliberately offer; the copy should inform, not extract consent.
- Don't trust the declared routing choice. Check it against observed traffic and show the
  mismatch — an agent that looks metered and isn't is the failure nobody spots.
- Don't present agents as required for core features.
- Don't hide the BYOK metering/moderation tradeoff.
- Don't trust agent-claimed scope — UI reflects server-validated scope only (FR-027).

## Access scope panel *(Phase 2)*
Per-agent card showing read clearance, groups, write mode, max write level and writable
groups — alongside the **owner's** clearance, so the gap between them is visible at a glance.
- **An agent is its own principal, bounded by its owner.** Effective access is
  `min(agent, owner)` for clearance and the intersection for groups, recomputed at every
  token mint. Show the owner's level next to the agent's precisely so an over-privileged
  agent looks wrong.
- **Write is a separate grant, off by default.** Reading the workspace never implies adding
  to it. Default write mode is `create only`; update and delete are separate and should stay
  rare, because an agent that can overwrite the knowledge base has a far larger blast radius
  than one that can only add.
- **Derived writes never widen access** — anything written from retrieved context inherits
  the highest clearance and the groups of its sources, computed server-side from the
  retrieval trace. The agent may be more restrictive, never less.
- Agent-authored content is badged, and governed artifact types land as `draft`.

## Three things called "agent" — keep them apart

This screen is where the distinction has to be legible, because all three share the word.

| | What it is | Where it runs | Acts as | Where you see it |
|---|---|---|---|---|
| **Built-in query agent** | AISAT's LangGraph RAG graph that answers chat | AISAT (Python tier) | the *querying member* | Chat + its debug drawer — **never** on this screen |
| **External / local agent** | An MCP client (openClaw, hermes, a script) driving its own loop | the member's machine or CI | its own registered identity | Registered devices + **Agent activity** |
| **Long-horizon task** | Multi-step work with checkpoints and a cost cap | **the AISAT worker** | a registered agent's identity | **Long-horizon tasks** |

The third row is the one that misleads. A long-horizon task is *not* executed by the local
agent — the registered agent supplies the **identity** (workspace scope, tool access,
clearance, routing mode); the loop itself runs server-side, which is what makes
checkpoint/resume and stale-worker re-queue possible (FR-028). Label the picker **Run as**,
never "Run on", and say where execution happens.

Two consequences the UI must show rather than discover at run time:

- **BYOK agents cannot run long-horizon tasks.** The worker cannot make AI calls with a key
  it does not hold, and escrowing a member's provider key to run background jobs would
  defeat BYOK. Render the option as ineligible with that reason.
- **An external agent's own loop produces no `agent_run` row.** It will never appear under
  Long-horizon tasks, which is precisely why the Agent activity panel exists — without it,
  the most active integrations on the system are the least visible.

## Agent activity panel *(Phase 2)*
The screen's other sections answer *what an agent may do* (Access scope) and *what AISAT
asked it to do* (Long-horizon tasks). This one answers **what it actually did** — the only
one of the three that covers an externally-driven agent (an MCP client such as openClaw or
hermes), which never appears as a task because it drives and AISAT is the resource.

Per selected agent, visible to the agent's **owner** as well as to workspace admins:

- **Health strip**: in-flight calls, 24h call count, error count and rate, denial count.
  `connected` is a heartbeat, not health — an agent can be connected and failing every call.
- **Tool-call table**: per tool — calls, errors, denials. Shows what the agent actually
  reaches for, which is usually narrower (or stranger) than what it was granted.
- **Denied operations — the panel that justifies this screen.** Each denial with its reason
  (`write_above_max_level`, `missing_group`, `tool_not_allowed`, `budget_exhausted`), the
  concrete values involved, and what to change. *A permission-scoped agent that is quietly
  being denied looks identical to one that is working* — without this panel, a
  misconfigured scope reads as "the agent isn't very good".
- **Wrote · 24h**: created count and drafts awaiting promotion, linking to the
  agent-authored view in the Library.
- **Spend today** against the agent's daily budget.

## LLM routing is a convenience choice — write it that way
The registration question is **who supplies the LLM credential**, and the headline benefit of
the AISAT gateway is that *the member never obtains or manages a key*. Metering and moderation
follow from that choice; they are not the pitch. Three answers:

| Option | Copy should lead with |
|---|---|
| **Use the AISAT gateway** *(easiest)* | No API key to obtain or manage. Paid with workspace credits. |
| **Use your own AI provider** | You already have a provider account and want to keep using it. |

**Exactly two options — resist adding a third.** Vendor-hosted agents (GitHub Copilot and
similar, where inference runs on the vendor's servers with no endpoint to redirect) are *not* a
third choice: for everything the system does they are identical to the second option — no AI
traffic reaches AISAT, the credential is MCP-only, credits cover tool operations only, and
long-horizon tasks are unavailable. The one thing that differs is whether the member *could*
switch to the gateway, which is help-text.

Capture it as an **optional checkbox under the second option** ("this agent can't be pointed at
a gateway"), and say on the control that it changes nothing except whether AISAT later suggests
a switch they can't make. A choice that changes no behaviour must not look like a mode.

**Keep the vocabulary identical across the whole screen.** Device cards, the confirm step, the
"Run as" picker and the activity panel all name the same two things — *AISAT gateway* and *own
provider key*. The old term "server-routed" conflated LLM routing with tool routing; tool calls
*always* run through AISAT, so the only thing ever in question is where AI calls go. The confirm
step must reflect the member's actual choice, not a hardcoded default.

**Don't write the own-key option as a confession.** No "you accept full responsibility", no
blocking acknowledgement checkbox. State what changes — the provider bills those calls,
moderation happens on their side, workspace credits still cover tool operations — and note
that everything the agent does *to your data* is recorded either way. A liability waiver in
front of a legitimate product option reads as disapproval and adds friction to a choice you
deliberately offer.

## What's observable, per option
End each agent's panel with the honest scope. Neutral, not cautionary:
- **AISAT gateway**: AI calls and tool calls both run through us — prompts, tokens, cost and
  data operations all recorded and traceable.
- **Own key**: everything the agent did *to your data* is here; what it said to its model is at
  the provider. Name the switch (move to the gateway) as an option, not a correction.

## Setup check: declared vs observed *(the important one)*
The routing choice is **never taken on trust**. AISAT knows whether AI calls arrive at its
proxy for a given agent credential, so continuously compare the declared choice against
observed traffic and surface any mismatch at the top of the activity panel.

Treat this as **onboarding help, not policing**. A member picks the gateway precisely to avoid
fiddling with keys; if it silently doesn't take effect — most often a provider key still
exported in the agent's environment, which takes precedence over `LLM_BASE_URL` — they get none
of the benefit, no credits are spent, and every screen still reports the agent as fully
metered. Name the likely cause and link to setup help.

**Keep the whole panel consistent with the finding.** If no AI calls are arriving, the spend
figure must show tool operations only and say why — a warning banner above a spend number that
still counts LLM tokens is worse than no banner, because one of the two is lying.

## Allowed-tools picker
Phase 1's MCP surface is **read-only by default** plus the two HITL-gated Category-D action
tools: **`web_search`** (user+admin) and **`edit_note`** (requires `can_write` +
`note_update ∈ write_ops`). These two appear as toggleable Phase-1 tools with a small
`HITL` marker (every use is human-approved). The *broader* write tools (`ingest_document`,
`write_memory`, artifact writes, document creation) keep the `Phase 2` chip. The picker must
never imply a capability the server will refuse (FR-012, FR-041).

---

## Scope boundary: Agents vs the agent registry *(Phase 2)*

This screen is **runtime** — which devices are connected, credential and BYOK routing,
running long-horizon tasks and their cost caps. It answers *what is running right now*.

The Phase 2 `agent_registry` is **catalog** — what agents exist conceptually, their
purpose, capabilities, model and tools, for discovery by humans and by other agents via
`get_agent_registry`. It answers *what agents exist and what can they do*. The
relationship is "running processes" vs "installed packages".

**Decision:** this screen keeps its name and meaning; the registry is **not** a second
Agents screen. `agent_def` is a seeded `artifact_type`, so the catalog is a *facet of the
Library* (Type = `agent_def`), and registry entries are **mirrored from Git by default**
— agent definitions already live as files in repos, so retyping them into a form is the
manual data entry this product's own extraction rule bans. Mirrored entries are read-only
here with a link to their source path.

Carry a one-line cross-link in each direction: a connected device that corresponds to a
registered definition links to it, and a registry entry links to its running device if
one is connected. See [specs/draft-plan.md](../../../specs/draft-plan.md)
"Surfaces & naming (decided)".

| Affordance | Phase | Backing contract |
|---|---|---|
| Access scope panel (clearance, groups, write mode) | 2 | `agent_registry.clearance`, `agent_policies` write scope |
| Agent activity: health, tool calls, denials, writes, spend | 2 | Resource-level audit (Agent Access & Accountability, Decision 5) |
| Cross-link to the Library agent-definition facet | 2 | `agent_registry`; `get_agent_registry(capability)` |
| Category E tools in the allowed-tools list (typed knowledge) | 2 | `get_artifact_by_type`, `search_biz_rules`, `get_agent_registry`, `resolve_dependency_chain` |
