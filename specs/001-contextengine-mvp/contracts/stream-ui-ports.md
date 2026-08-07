# Contract: Agentic Stream UI & Trace Inspection (reusable ports)

**Plan**: [../plan.md](../plan.md) | **Status**: Design addition — the reusability seam for the browser-facing half of the agentic stream (FR-021, FR-031). It factors the chat surface and the debug panel into a small set of ports so the *same* components render **any** agent's stream, and so a host's run-detail (ours is RAG retrieval) plugs in as a registered section rather than a hard-coded panel. **Changes no Phase 1 behavior** — the same panel shows the same rows for the same query; this only names the render seam that today is a component reading one fixed `DebugTrace` shape, the same treatment [audit-ports.md](./audit-ports.md), [metering-ports.md](./metering-ports.md), [notification-ports.md](./notification-ports.md), and [approval-ports.md](./approval-ports.md) gave their backbones.

The Phase 1 stream UI is already correct on its *product* axes (streams tokens, renders nested agentic activity, shows every retrieval stage, links the Langfuse trace). But it is packaged as **components welded to four of *this* app's assumptions**: a RAG-shaped trace, our billing/clearance vocabulary, our app's state and design tokens, and our SSE transport. This contract names the seam that removes that welding. Ports are given in TypeScript (the SPA language); ContextEngine's retrieval inspector is presented at the end as **one binding of a generic `TraceSection`**, not as the panel itself.

> **Scope note — this is the UI analogue of the backend port work, and it is deliberately narrower.** The wire ([sse-events.md](./sse-events.md)) was *already* designed for reuse: `agent_step`/`tool_use`/`tool_result` are vendor-neutral and additive-by-`kind`. What was **not** reusable is everything above the wire: the panel that reads it, and the transport binding that feeds it. Those are what this contract fixes. Nothing here changes the event taxonomy except the one generalization in [Wire change](#wire-change-debugtrace--tracesection) below.

---

## Why: the four couplings this removes

| # | Today's coupling | Evidence it is a coupling | The port that removes it |
|---|------------------|---------------------------|--------------------------|
| 1 | The debug panel **is** a RAG-retrieval inspector | `DebugTrace` ([sse-events.md](./sse-events.md)) is a fixed struct of `bm25_scores`, `vector_scores`, `rrf_merged`, `reranker_before/after`, `index_tier: HOT\|COLD`, `chunk_type`, `mem0_injected`. `DebugPanel.tsx` (T103) reads those field names directly. Dropped into a non-RAG agent, **every row is meaningless** and the component does not compile against the host's trace | `TraceSection` + `TraceSectionRegistry` — the panel renders an **ordered list of opaque sections**; our retrieval detail is one registered `rag_retrieval` renderer, never the panel's schema |
| 2 | Domain vocabulary is baked into the shared surface | `done.credits_deducted` (billing), `approval_request.kind` (`enrich_accept`/`sensitivity_confirm`/…), `notification.category` (13 AISAT categories), and the clearance/workspace framing are consumed directly by chat chrome (`CreditBalance.tsx`, T099). A reuser inherits our billing and access model whether or not they have one | `ChromeSlots` — host chrome is injected as optional render slots; the kernel renders a run without knowing what a credit or a clearance is |
| 3 | Components live **inside** the app feature | `DebugPanel`, `CreditBalance`, and the thread all sit under `frontend/src/features/chat/` and lean on app router/state and design-system tokens (`--color-surface`, run-green). Nothing declares "this is a package with these props and zero app deps" — extraction today means hand-auditing every import | A `frontend/src/stream-ui/` **package boundary**, props-only, enforced by an ESLint `no-restricted-paths` rule (the SPA analogue of the Go `depguard` rule forbidding `kernel/` → `internal/`, T008) |
| 4 | The renderer is welded to our transport | The components are driven by our `EventSource` client over our SSE event names (`frontend/src/lib/sse.ts`, T032). Rendering *another* agent's stream means re-implementing the components, not re-binding a source | `StreamSource` — a transport port yielding normalized `ActivityEvent`s; our SSE client is one binding, a fixture/WebSocket/in-process agent is another |

The rule: **the stream-UI kernel is generic; only the `TraceSection` renderer set, the `ChromeSlots`, and the `StreamSource` binding are product-specific.** Everything that matters for the panel today (per-step scores, access-filter summary, token cost, credits, trace link) is preserved verbatim — it just stops being *the schema* and becomes *a registered section*.

> **This is a packaging refactor, not a behavior change.** FR-021 still shows every retrieval/generation step with scores, access-filter result, token cost, and credits deducted; SC-005 ("no step hidden") is unchanged and still gated by T100/T127. What changes is that a **second** host adds its own inspector without editing ours.

---

## Ports at a glance

```text
TRANSPORT (any) ── our SSE relay · a fixture · a WebSocket · an in-process agent
   │  StreamSource.subscribe(onEvent) → Unsubscribe
   ▼
┌── StreamRenderer (orchestration · pure reducer, no React, no app deps) ────────┐
│   reduce(ActivityEvent) → ActivityNode tree   (id/parentId nesting)     PURE   │
│   token/thinking deltas → transcript buffers                            PURE   │
│   trace sections → ordered TraceSection[] (payloads NEVER interpreted)  PURE   │
└───────────────────────────────────────────────┬───────────────────────────────┘
                                                 ▼
┌── AgentTraceInspector (generic view · props-only) ────────────────────────────┐
│   renders the ActivityNode tree: steps, nested sub-agents, tool pairs, status  │
│   delegates each TraceSection to ────────────────────────────────────────┐    │
└─────────────────────────────────────────────────────────────────────────┼─────┘
                                                                           ▼
┌── TraceSectionRegistry (the pluggable detail renderer · load-bearing seam) ───┐
│   RagRetrievalSection   bm25 · vector · RRF · rerank · tier · access · mem0    │
│   (register another: PlannerSection · EvalSection · SqlPlanSection — never     │
│    edit the inspector; an UNKNOWN kind falls back to GenericKeyValueSection)   │
└───────────────────────────────────────────────────────────────────────────────┘
        ChromeSlots (optional) → credits · clearance badge · approvals · notifications
```

Four seams a host can swap independently: the **`TraceSectionRegistry`** (its run-detail vocabulary), the **`StreamSource`** (its transport), the **`ChromeSlots`** (its product chrome), and the **theme contract** (its design tokens). The reference impl uses our SSE relay and a RAG section, but nothing in the port signatures requires either.

---

## Domain types

```typescript
// frontend/src/stream-ui/ports.ts — ZERO imports from features/, lib/, or the app store.

/** A normalized activity beat, transport-agnostic. The SSE binding maps
 *  agent_step / tool_use / tool_result onto this; another binding maps its own wire.
 *  This is the ONLY vocabulary the inspector understands. */
export type ActivityEvent =
  | { op: "step_start";  id: string; parentId: string | null; kind: string; label: string; detail?: unknown }
  | { op: "step_end";    id: string; status: NodeStatus; detail?: unknown }
  | { op: "tool_start";  id: string; parentId: string | null; name: string; title?: string; input?: unknown }
  | { op: "tool_end";    id: string; status: "ok" | "error"; output?: string; durationMs?: number }
  | { op: "token";       delta: string }
  | { op: "thinking";    delta: string }
  | { op: "stage";       stage: string }                 // coarse run stage (our `status` event)
  | { op: "section";     section: TraceSection }         // run-detail, opaque (see below)
  | { op: "end";         summary: RunSummary }
  | { op: "failed";      code: string; message: string };

export type NodeStatus = "running" | "ok" | "error" | "degraded";

/** The rendered tree node. `kind` is host-extensible: "node" | "subagent" | "skill"
 *  | "planner" | anything. An unknown kind renders as a generic collapsible row —
 *  NEVER dropped, NEVER an error (the additive-kind guarantee, sse-events.md). */
export interface ActivityNode {
  id: string;
  parentId: string | null;
  type: "step" | "tool";
  kind: string;
  label: string;
  status: NodeStatus;
  detail?: unknown;          // display hint ONLY — never an access decision
  startedAt: number;
  endedAt?: number;
  children: ActivityNode[];
}

/** ONE unit of run-detail. The load-bearing generalization: the kernel treats
 *  `payload` as OPAQUE and hands it to the registered renderer for `kind`.
 *  AISAT's retrieval trace is `kind: "rag_retrieval"` — one section, not the schema. */
export interface TraceSection {
  kind: string;              // "rag_retrieval" | "planner" | "eval" | host-defined
  label: string;             // human-readable section header
  payload: unknown;          // OPAQUE to the kernel — shape owned by the renderer
  order?: number;            // optional display rank; stable sort, ties by arrival
}

/** Terminal run facts the kernel DOES understand. Domain cost/spend is NOT here —
 *  it arrives via ChromeSlots.runFooter, so a host with no billing renders nothing. */
export interface RunSummary {
  usage?: { input: number; output: number };
  traceUrl?: string;         // deep link to the host's observability (ours: Langfuse)
  extra?: Record<string, unknown>;  // host-defined; passed through to ChromeSlots
}
```

---

## Port: `TraceSectionRenderer` — the pluggable detail renderer (the load-bearing seam)

```typescript
/** ONE renderer for ONE section kind. RagRetrievalSection is the Phase 1
 *  implementation; a planner trace, an eval breakdown, or a SQL plan is added by
 *  REGISTERING another renderer — never by editing AgentTraceInspector. This is the
 *  stream-UI analogue of audit's Sink, notification's Channel, and metering's Pricer:
 *  the one place a new deployment plugs in its own vocabulary. */
export interface TraceSectionRenderer<P = unknown> {
  kind: string;
  /** Narrow `unknown` → P at the boundary. MUST return false rather than throw on a
   *  shape it does not recognize, so a version-skewed payload degrades to the generic
   *  renderer instead of blanking the panel. */
  accepts(payload: unknown): payload is P;
  render(payload: P, ctx: RenderContext): ReactNode;
}

export interface TraceSectionRegistry {
  register(r: TraceSectionRenderer<never>): void;
  /** Returns the registered renderer, or the GENERIC fallback for an unknown kind.
   *  MUST NEVER return undefined — an unrenderable section still renders. */
  resolve(kind: string): TraceSectionRenderer<never>;
}

/** Everything a renderer may need that is NOT the payload. Deliberately tiny:
 *  a renderer that needs app state is a renderer in the wrong package. */
export interface RenderContext {
  copy: (text: string) => void;
  formatNumber: (n: number) => string;
  dense: boolean;            // compact mode (side panel) vs. expanded
}
```

## Port: `StreamSource` — the transport binding

```typescript
/** Yields normalized ActivityEvents from SOME transport. `SseStreamSource` (our
 *  relay, frontend/src/lib/sse.ts) is one binding; `FixtureStreamSource` (test-only,
 *  replays a recorded script) is the second, and is what PROVES the seam. */
export interface StreamSource {
  kind: string;              // "sse" | "fixture" | "websocket" | "inprocess"
  subscribe(onEvent: (e: ActivityEvent) => void): () => void;  // returns unsubscribe
}
```

## Port: `ChromeSlots` — the product-chrome escape hatch

```typescript
/** Optional render slots. EVERY field is optional: omitting all of them yields a
 *  fully functional agent chat with no billing, no clearance, no approvals — which
 *  is exactly what a reusing host gets before it opts in. This is what keeps
 *  `credits_deducted`, clearance badges, and notification categories OUT of the kernel. */
export interface ChromeSlots {
  header?: () => ReactNode;                          // ours: CreditBalance (T099)
  runFooter?: (s: RunSummary) => ReactNode;          // ours: credits_deducted + trace link
  messageBadge?: (m: RenderedMessage) => ReactNode;  // ours: clearance badge
  interrupt?: (raw: unknown) => ReactNode;           // ours: approval_request card (T121a)
  emptyState?: () => ReactNode;
}
```

---

## The theme contract — `--su-*`

The fourth swappable seam, and the one a client app touches first. `stream-ui/` **never emits a raw color, radius, or font utility** (`bg-slate-800`, `rounded-lg`, `font-mono`). Every visual decision reads a `--su-*` custom property with a built-in fallback, so the package renders coherently in a host that sets nothing and reskins completely in a host that sets everything — **without a fork and without a build step**.

| Group | Token | Governs |
|---|---|---|
| **Color** | `--su-canvas` · `--su-surface` · `--su-surface-2` · `--su-border` | page, panel, elevated panel, dividers |
| | `--su-text` · `--su-text-muted` | primary + secondary text |
| | `--su-accent` · `--su-info` · `--su-warn` · `--su-danger` | running/ok · sub-agent · **degraded** · error |
| **Shape** | `--su-radius-card` · `--su-radius-control` · `--su-radius-pill` | panels · buttons/rows · status chips + step dots |
| | `--su-border-width` | hairline vs. heavier separation |
| **Density** | `--su-space` | base unit; row padding and section gaps derive from it |
| | `--su-row-gap` · `--su-indent` | activity-row rhythm · tree nesting indent per level |
| **Type** | `--su-font-sans` · `--su-font-mono` | prose · IDs, scores, durations, token counts |
| | `--su-text-size` · `--su-text-size-mono` | base + monospace scale |

**Every reference carries a fallback**: `var(--su-surface, #1E293B)`. That is what makes invariant 3 (zero app deps) survivable — the package cannot import a token file, so the fallback *is* its default theme.

**The host maps, the package never knows.** A consuming app keeps its own token vocabulary and binds it in one place:

```css
:root {
  /* the client app's own design system — the package never references these */
  --brand-green: #22C55E;  --brand-panel: #1E293B;

  /* the one mapping layer: client tokens → the --su-* contract */
  --su-accent:  var(--brand-green);
  --su-surface: var(--brand-panel);
  --su-radius-card: 2px;        /* square-cornered client? just set it */
  --su-font-mono: "JetBrains Mono", monospace;
}
```

Re-theming is that block. No component edit, no fork, no rebuild of the package.

> **Why this is a contract clause and not a styling note.** Utilities like `rounded-lg` and `bg-surface` are *baked into markup* — they are as much a coupling as importing the app store, just a less obvious one. A client whose brand is square-cornered or non-monospace has no seam and forks the components, at which point every later fix diverges. Naming the tokens is what turns "you could restyle it" into something a CI check can hold.

---

## Invariants (load-bearing, not cosmetic)

1. **Opaque payloads.** The kernel never reads inside `TraceSection.payload`, and never branches on `section.kind` outside `TraceSectionRegistry.resolve`. A `grep` for `bm25`, `rrf`, `mem0`, `clearance`, or `credits` under `stream-ui/` MUST return zero hits — that grep **is** the conformance check for coupling #1.
2. **Unknown degrades, never drops.** An unknown `ActivityNode.kind`, an unknown `section.kind`, and a payload failing `accepts()` all render (generic row / generic key-value table). Nothing is silently discarded and nothing throws. This extends the existing additive-`kind` guarantee ([sse-events.md](./sse-events.md)) from the wire up into the renderer.
3. **Props-only, zero app deps.** `stream-ui/` imports nothing from `features/`, `lib/`, the router, or the app store. Enforced mechanically by ESLint `import/no-restricted-paths` — the SPA analogue of the Go `depguard` rule (T008). A violation fails CI, so "extractable" stays true instead of decaying.
4. **Display-only, never an access decision.** Inherited verbatim from [sse-events.md](./sse-events.md): `detail`, tool `input`/`output`, and every section payload are display hints. The panel never gates on them, and a dropped/truncated section is cosmetic — the authoritative record is in Postgres ([data-model.md](../data-model.md)).
5. **Theme by contract, not by import.** `stream-ui/` styles **only** through the `--su-*` tokens above, each with a fallback. It emits no raw color/radius/font utility and imports no design-system module, so it renders coherently in a host that sets nothing and reskins fully — colour, corner radius, density, and typeface — from one `:root` block in a host that sets everything. Mechanically checked: a scan of `stream-ui/**` for hard-coded hex/`rgb()`, for Tailwind palette utilities (`bg-slate-*`, `text-emerald-*`, …), and for literal `rounded-*`/`font-mono` must return zero hits.
6. **Observation, not control.** The inspector emits no run-control actions. The only member→run control path remains the HITL `approval_request` → `POST /approvals/{id}/resolve` loop, surfaced through `ChromeSlots.interrupt` (FR-040).

---

## Wire change: `DebugTrace` → `TraceSection`

The one taxonomy change this contract makes. `GET /query/{streamId}/debug` currently returns a fixed `DebugTrace` object. It becomes a **section envelope** whose Phase 1 content is byte-identical:

```typescript
// GET /query/{streamId}/debug  →
interface DebugResponse {
  sections: TraceSection[];   // Phase 1 emits exactly one: kind="rag_retrieval"
  summary: RunSummary;
}
```

The Phase 1 `rag_retrieval` payload is **the existing `DebugTrace` struct unchanged** (`intent`, `tool_called`, `index_tier`, `access_filter`, `bm25_scores`, `vector_scores`, `rrf_merged`, `reranker_before/after`, `chunk_type`, `mem0_injected`, `model_used`, `token_cost`, `credits_deducted`, `langfuse_trace_url`) — moved, not edited. So:

- **No field is lost**, and FR-021 / SC-005 assertions (T100) keep asserting the same fields, one level deeper.
- A host with a **different** pipeline emits its own `kind` and registers its own renderer — no fork of ours, no unused `bm25_scores: []`.
- A host with **several** detail views (retrieval *and* a planner trace *and* an eval breakdown) emits several sections — previously impossible without widening the struct for everyone.

> **Why change the wire now rather than wrap it client-side.** Wrapping would leave the *server* contract asserting that every run is a RAG run, which is the coupling itself — the second host would still have to fork `DebugTrace` to say anything. Doing it in Phase 1 costs one nesting level in a not-yet-implemented handler (T102) and one test edit (T100); doing it after implementation is a breaking change to a shipped endpoint. This is the same reasoning that made the backend port extractions Phase-1 work rather than Phase-2 cleanup.

---

## Binding: ContextEngine's retrieval inspector

The AISAT panel is **one registration**, not the framework:

```typescript
// frontend/src/features/chat/trace/rag-retrieval.tsx — APP code, not stream-ui/.
registry.register<RagRetrievalPayload>({
  kind: "rag_retrieval",
  accepts: (p): p is RagRetrievalPayload =>
    !!p && typeof p === "object" && "rrf_merged" in p,
  render: (p, ctx) => <RagRetrievalSection trace={p} dense={ctx.dense} />,
});
```

Everything AISAT-specific lives on this side of the seam: the score tables, the HOT/COLD tier chip, the `access_filter` clearance summary, the `mem0_injected` row. The chat surface then composes the generic kernel with our chrome:

```typescript
<AgentChat
  source={new SseStreamSource(`/query/${streamId}`)}
  registry={registry}
  chrome={{
    header:    () => <CreditBalance />,                    // T099
    runFooter: (s) => <RunCost summary={s} />,             // credits_deducted + Langfuse link
    interrupt: (raw) => <ApprovalCard request={raw} />,    // T121a
  }}
/>
```

A reusing host writes the same two calls with **its** registrations and **no** `chrome` — and gets a working agentic chat plus trace inspector with zero AISAT concepts in it.

---

## Contract test obligations

- **Registry dispatch:** a section whose `kind` has a registered renderer renders through it; an **unregistered** `kind` renders through the generic key-value fallback (not dropped, not thrown); a registered renderer whose `accepts()` rejects the payload **also** falls back to generic. `resolve()` never returns `undefined`.
- **Second-source conformance (the reusability proof).** A shared `StreamUIContract` suite — build the tree, pair tools, close steps, order sections, reach a terminal summary — runs against **both** `SseStreamSource` (our relay) **and a second, test-only `FixtureStreamSource`** replaying a **non-RAG** agent script (a planner spawning two sub-agents, each with nested tool calls, emitting a `planner` section and **no** `rag_retrieval`). The suite passes **unchanged** against both. This is the stream-UI analogue of T091a's second fixture `Pricer` and T027a's `ParityContract`: the reuse claim is **demonstrated by a genuine second implementation**, never merely asserted.
- **Tree construction:** `id`/`parentId` nesting reconstructs correctly under **out-of-order and interleaved** arrival; concurrent `tool_start`s with distinct `id`s pair to their own `tool_end`s; a `step_end` with no matching `step_start` is ignored without corrupting the tree; an orphan `parentId` attaches at root rather than vanishing.
- **Forward compatibility:** an `ActivityEvent` with an unknown `kind` (`"skill"`, `"planner"`, or a value invented after this contract) renders as a generic collapsible row and the suite still passes — asserting the additive-`kind` guarantee end-to-end, wire → renderer.
- **Zero-coupling grep:** an automated check asserts no occurrence of `bm25`, `rrf`, `rerank`, `mem0`, `clearance`, `credits`, `workspace`, or `access_level` in `frontend/src/stream-ui/**` (invariant 1), and no import from `features/`, `lib/`, or the store (invariant 3).
- **Theme swap (the reskin proof).** Rendering the same run twice — once with no `--su-*` set, once under a `:root` overriding `--su-accent`, `--su-surface`, `--su-radius-card`, and `--su-font-mono` — produces **different computed styles from identical markup**, with no component prop changed and no rebuild. Paired with a static scan asserting `stream-ui/**` contains no hard-coded hex/`rgb()`, no Tailwind palette utility (`bg-slate-*`, `text-emerald-*`, …), and no literal `rounded-*`/`font-mono` (invariant 5). The scan is what stops the seam decaying — one merged `rounded-lg` and a client's square-cornered brand silently stops working.
- **Chrome-free render:** the chat surface mounts with `chrome={}` (all slots omitted) and renders a complete streaming run — tokens, activity tree, sections, terminal summary — with **no** credit balance, clearance badge, or approval affordance, and no console error. This is the "what a reusing host gets on day one" assertion.
- **Parity with the panel today:** rendering the Phase 1 `rag_retrieval` section through `RagRetrievalSection` displays every field FR-021 requires (per-step scores, access-filter summary, token cost, credits deducted, trace link) — SC-005 is unchanged by the refactor.
