# Feature Specification: AISAT-INTEL MVP — AI-Powered Shared Second Brain (Phase 1)

**Feature Branch**: `001-contextengine-mvp`

**Created**: 2026-06-05

**Status**: Draft

**Input**: User description: "pls refer to content of draft-idea.md" — AISAT-INTEL MVP, Phase 1 Core App design spec.

## Overview

AISAT-INTEL is an AI-powered shared second brain for work teams. Members upload files, paste links, and add notes; the system automatically ingests, organizes, and makes that knowledge queryable through a conversational AI interface. The AI only ever surfaces knowledge the requester is authorized to see, with access control enforced at the data layer rather than by prompt instructions.

This specification covers **Phase 1 (Core App)** only. The Evaluation Suite (Phase 2) and automated security red-teaming (Phase 3) are out of scope, except for a minimal evaluation seed set and the structural prompt-injection defenses that must ship in Phase 1 because untrusted content flows through the core data path.

## Clarifications

### Session 2026-06-05

- Q: How many clearance levels exist and what access level do new documents get by default? → A: Fixed ladder of 5 ordered levels (1–5); a new document defaults to the uploader's own clearance level when none is chosen.
- Q: How must cached answers be scoped so a higher-clearance answer never leaks to a lower-clearance member? → A: Any cached answer is keyed by workspace + requester clearance + the authorized document set, and is reused only for requesters whose authorization scope is identical.
- Q: At what usage level should the near-limit warning fire? → A: An admin-configurable threshold per workspace, defaulting to 80% of the workspace balance and per-user daily limit.
- Q: What is the maximum per-file size for ingestion? → A: An admin-configurable per-file size limit per workspace, defaulting to 50 MB; oversize files are rejected at the boundary with a clear message.
- Q: How long are raw prompt/response bodies retained before only metadata/aggregates remain? → A: 30 days, after which raw bodies are purged and only PII-scrubbed metadata, hashes, and aggregates are kept.

### Session 2026-07-23

- Q: For a long-horizon task (US7), where does the agent loop actually execute — on the member's machine or on the server? → A: **On the AISAT worker.** A registered local agent supplies the *identity* a task runs under (workspace scope, tool access, routing mode), not the runtime. This is what FR-028's checkpoint/resume and the stale-heartbeat re-queue require: a task whose worker dies is re-queued onto the server-side pool, which is only meaningful for server-side execution. An external agent that drives its own loop against `/llm/proxy` + the MCP server is a *different* interaction and produces no `agent_run` row.
- Q: Can a bring-your-own-key agent run a long-horizon task? → A: **No — long-horizon tasks require server-routed mode.** The worker executes the loop on AISAT's side and cannot make AI calls with a provider key it does not hold; escrowing a member's key to run background jobs would defeat the purpose of BYOK (FR-026). A BYOK agent can still use every MCP tool by driving its own loop from its own client. Surface this as an ineligible option with the reason, not as a silent failure at run time.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ingest knowledge into a searchable library (Priority: P1)

A team member uploads documents (PDF, DOCX, markdown/plain text, images) or writes a note, optionally attaching web links. For a note with links, the member can request enrichment: the system crawls the links, distills each page aligned to the note's intent, and proposes a draft the member reviews and accepts. The system converts, organizes, auto-tags, and indexes the content, then shows real-time progress. Once complete, the content is queryable and browsable in the library.

**Why this priority**: Nothing else in the product delivers value without knowledge in the system. Ingestion is the foundational entry point and the first thing a new user does.

**Independent Test**: Upload a PDF and create a note with an attached URL, run Enrich, accept the proposed draft, and confirm both items appear in the library with auto-generated tags and a summary — without using any query or team features.

**Acceptance Scenarios**:

1. **Given** an authenticated member with available credits, **When** they upload a supported file (PDF/DOCX/markdown/image), **Then** the system ingests it, assigns auto-taxonomy tags and a summary, and reports completion via live status.
2. **Given** a note with one or more attached web links, **When** the member clicks **Enrich**, **Then** the system crawls the links, distills each page aligned to the note's intent, and streams a **draft suggestion**; the note body and index are unchanged until the member **accepts** the draft, at which point only the accepted note body is indexed and the crawled sources are stored as citation metadata.
3. **Given** a member who finds an enrichment draft unsatisfactory, **When** they click **Enrich** again, **Then** the system re-runs enrichment and proposes a fresh draft, with no residual state from the discarded one.
4. **Given** a pasted bare URL with no note body, **When** the member submits it, **Then** the system creates a note whose draft body is the page summary, subject to the same accept gate.
5. **Given** an uploaded image or diagram, **When** ingestion runs, **Then** a text caption describing the image is generated and stored alongside it.
6. **Given** an unsupported source type (e.g., video/audio in Phase 1), **When** a member attempts to ingest it, **Then** the system clearly indicates the type is not yet supported rather than failing silently.
7. **Given** a file larger than the workspace's per-file size limit (default 50 MB), **When** a member attempts to upload it, **Then** the system rejects it at the boundary with a clear over-size message rather than failing silently.
8. **Given** an upload or note, **When** the member chooses an access level no higher than their own clearance, **Then** the document is stored at that level; absent a choice, it defaults to the member's own clearance level.

---

### User Story 2 - Ask questions and get access-scoped, cited answers (Priority: P1)

A member asks a natural-language question in a conversational interface. The AI retrieves the most relevant content from the member's personal knowledge and the shared workspace knowledge they are cleared to see, then answers with citations to the source documents. The assistant remembers context across the session.

**Why this priority**: This is the core value proposition — turning ingested knowledge into answers. Together with US1 it forms the minimum viable product loop.

**Independent Test**: After ingesting a few documents, ask a question whose answer lives in one of them and confirm the response cites the correct source and never references documents above the member's clearance.

**Acceptance Scenarios**:

1. **Given** ingested documents the member is authorized to see, **When** they ask a related question, **Then** the assistant returns a relevant answer with citations to the contributing source documents.
2. **Given** documents above the member's clearance or owned by other members, **When** they ask a question, **Then** those documents are never retrieved, cited, or reflected in the answer.
3. **Given** a multi-turn conversation, **When** the member asks a follow-up that depends on prior context, **Then** the assistant uses remembered session context to answer coherently.
4. **Given** an answer with retrieved sources, **When** the answer finishes streaming, **Then** 2–3 suggested follow-up question chips appear below the sources strip; clicking one populates the composer and immediately submits the question (FR-031).
5. **Given** a refused or zero-source answer, **When** rendered, **Then** no follow-up chips are shown (FR-031).
6. **Given** a structured-data question (e.g., about employees, projects, or metrics), **When** asked, **Then** the assistant answers from the structured data source scoped to the workspace.
7. **Given** input that is disallowed or an obvious prompt-injection attempt, **When** submitted, **Then** the system refuses before performing retrieval or consuming credits, and records the event.
8. **Given** a document containing embedded instructions ("ignore previous instructions…"), **When** that document is retrieved as context, **Then** the assistant treats it as reference material and does not follow instructions found inside it.

---

### User Story 3 - Access-controlled team workspace (Priority: P2)

Members operate within a shared workspace that combines personal knowledge and team knowledge. Each member has a clearance level; retrieval and browsing are strictly scoped so members see only their own documents plus shared documents at or below their clearance. Owners/admins manage membership and invitations.

**Why this priority**: Multi-tenant access control is what makes the product safe for team use and differentiates it from a personal tool. It builds on US1/US2 but is required before real teams can adopt it.

**Independent Test**: With two members at different clearance levels in one workspace, confirm each sees only the documents permitted to them in both the library and query results, and that workspace isolation prevents any cross-workspace visibility.

**Acceptance Scenarios**:

1. **Given** a workspace with members at different clearance levels, **When** each queries or browses, **Then** each sees only their personal documents plus shared documents at or below their clearance.
2. **Given** two separate workspaces, **When** a member of one queries, **Then** no content from the other workspace is ever returned.
3. **Given** a workspace owner/admin, **When** they invite a person by email, **Then** the invitee can accept and join with an assigned role and clearance, and the invite can be revoked.
4. **Given** an uploader, **When** they set a document's access level, **Then** they cannot set it above their own clearance.

---

### User Story 4 - Credit-based usage metering and budgets (Priority: P2)

Every AI operation (ingestion, captioning, querying, reranking) deducts from a shared workspace credit balance in real time. Members see remaining credits; the system warns as limits approach and blocks gracefully when exhausted. Independent tenant, per-user daily, and per-call ceilings prevent runaway cost and abuse.

**Why this priority**: Cost control is essential to operate the AI features sustainably and to prevent abuse, but the core knowledge loop (US1/US2) can be demonstrated before billing is fully wired.

**Independent Test**: Perform AI operations and confirm the credit balance decrements by the documented amounts, that a near-limit warning appears, and that operations are blocked with a clear message (not a silent error) once the balance is exhausted.

**Acceptance Scenarios**:

1. **Given** a workspace with a credit balance, **When** an AI operation runs, **Then** the appropriate credit cost is deducted in real time and reflected in the displayed balance.
2. **Given** usage approaching a workspace or per-user daily limit, **When** the configured warning threshold (admin-configurable per workspace, default 80%) is crossed, **Then** the member sees a warning banner with an upgrade option.
3. **Given** an exhausted credit balance, **When** a member attempts an AI operation, **Then** it is blocked with a clear "payment required / limit reached" message rather than failing silently.
4. **Given** a retried or accidentally double-submitted operation, **When** it is processed, **Then** credits are deducted only once.
5. **Given** a new or trial account, **When** it consumes credits, **Then** stricter new-account and per-IP cumulative ceilings apply to prevent free-credit farming.

---

### User Story 5 - Observable debug panel (Priority: P2)

For every answer, a developer-facing debug panel exposes the internal reasoning: detected intent, which tool was called, which index tier answered, access filtering applied, hybrid/rerank scores, chunk expansion, injected memory, model used, token cost, and credits deducted, with a link to the full trace.

**Why this priority**: The product's stated audience is a developer/hiring showcase where every architectural pattern must be observable and named. It is high-value for the target audience but not required for the basic knowledge loop.

**Independent Test**: Run a query and confirm the debug panel displays each retrieval and generation step with its associated scores, the access filter result, token cost, and credits deducted.

**Acceptance Scenarios**:

1. **Given** any completed query, **When** the member opens the debug panel, **Then** it shows the intent, tool called, index tier, access-filter summary, retrieval/rerank scores, model used, token cost, and credits deducted.
2. **Given** a query that was access-filtered, **When** the panel is viewed, **Then** it reports how many documents were filtered out by clearance.
3. **Given** a completed query, **When** the member follows the trace link, **Then** they can view the full end-to-end trace of the request.

---

### User Story 6 - Admin usage dashboard (Priority: P3)

A workspace admin views per-user and per-feature AI usage, credit consumption, and cost, and manages member limits.

**Why this priority**: Useful for workspace operators but not required to demonstrate the core experience.

**Independent Test**: As an admin, generate usage across multiple members and confirm the dashboard shows per-user and per-feature consumption and cost.

**Acceptance Scenarios**:

1. **Given** AI activity across members, **When** the admin opens the dashboard, **Then** per-user and per-feature usage and cost are shown.
2. **Given** the dashboard, **When** the admin adjusts a member limit, **Then** the new limit is enforced on subsequent operations.

---

### User Story 7 - Long-horizon tasks via a local agent (Priority: P3)

A member optionally connects a local agent to the workspace to run complex, multi-step tasks (e.g., "summarize all Q3 reports and draft an email"). The local agent uses workspace-scoped tools and, by default, routes its AI calls through the server so usage is metered and audited. Long-running tasks survive interruptions and can be cancelled, and are bounded by a hard per-task cost cap.

**Why this priority**: A powerful but additive capability. All core features must work fully without any local agent present; only long-horizon tasks require one.

**Independent Test**: Register a local agent, start a long-horizon task, interrupt the worker, and confirm the task resumes and completes (or can be cancelled), with usage metered and audited and the per-task cost cap honored.

**Acceptance Scenarios**:

1. **Given** no local agent is connected, **When** a member uses any core feature (ingest, query, library, credits, debug panel), **Then** all of them function fully; only long-horizon tasks are unavailable.
2. **Given** a registered local agent in default (server-routed) mode, **When** it performs AI operations, **Then** usage is metered against credits and recorded in the audit log.
3. **Given** a running long-horizon task, **When** the worker process is interrupted, **Then** the task resumes from its last checkpoint rather than being lost.
4. **Given** a running long-horizon task, **When** the member cancels it (including by closing the tab), **Then** the task stops and reports a cancelled status.
5. **Given** a long-horizon task, **When** its spend reaches the per-task cost cap, **Then** it halts and notifies the member, independent of the daily budget.
6. **Given** any agent result, **When** it returns tool arguments, **Then** the system validates them against the device's authorized workspace scope and never honors a claim of access to a workspace it was not issued credentials for.
7. **Given** a long-horizon task that reaches a step flagged as state-changing or outward-reaching, **When** the step requires human approval, **Then** the task **pauses** (surfacing an approval request to the member) and consumes no further credits until resolved; on **approve** it resumes exactly where it paused, and on **reject** or timeout it ends cleanly without performing the action (FR-040, SC-014).
8. **Given** an agent (user/admin role) running a task that needs fresh external information, **When** it invokes **web-search**, **Then** each intended fetch is surfaced for explicit member confirmation and runs only on approval; a rejected search performs no fetch and spends nothing for it (FR-041, FR-040).
9. **Given** an agent proposing a **note-edit** to an existing note within its `min(agent, owner)` clearance, **When** the edit is generated, **Then** it does not change the stored note until a member approves the diff; the approved edit never raises the note's access level above its source floor, the agent cannot edit a note above its clearance or create a new document, and a rejected edit leaves the note unchanged (FR-041, FR-040, SC-015).

---

### User Story 8 - Stay informed through notifications (Priority: P3)

Members receive notifications about workspace activity that concerns them — ingestion finishing, invites, credit warnings and exhaustion, a long-horizon task halting at its cost cap, a document being shared with them or their clearance changing, a new member joining (admins), and admin broadcasts. Notifications appear in real time on an in-app bell/inbox and, for categories the member has opted into, are also delivered by email. Each member controls, per category, whether they receive in-app and/or email notifications.

**Why this priority**: Notifications increase engagement and surface actionable events, but the core knowledge loop (US1/US2) and the flows that *produce* the events function without them. It builds on existing ingestion, invite, credit, and agent-run flows.

**Independent Test**: As a recipient, trigger an event (e.g., finish an ingestion), confirm a notification appears in the in-app inbox in real time and increments the unread badge; mark it read and confirm the badge decrements; disable that category's email channel and confirm a subsequent event sends no email while still appearing in-app.

**Acceptance Scenarios**:

1. **Given** a member with default preferences, **When** an event concerning them occurs (e.g., their ingestion completes), **Then** a notification is persisted to their inbox and pushed in real time, incrementing the unread count.
2. **Given** an unread notification, **When** the member marks it read (individually or via mark-all-read), **Then** its read state persists and the unread count decrements accordingly.
3. **Given** a member who has disabled the email channel for a category, **When** an event in that category occurs, **Then** no email is sent for it, though the in-app notification is still delivered if the in-app channel remains enabled.
4. **Given** a member who has disabled both channels for a category, **When** an event in that category occurs, **Then** no notification is delivered to that member for that category.
5. **Given** two members in different workspaces (or a different recipient in the same workspace), **When** a notification is generated for one, **Then** it is never visible or delivered to the other.
6. **Given** a workspace admin, **When** they send a broadcast announcement, **Then** every current member of that workspace receives it subject to their own per-channel preferences.
7. **Given** a transient email-provider failure, **When** an email notification cannot be delivered, **Then** it is retried and, on exhausting retries, parked for later inspection rather than silently dropped, while the in-app notification is unaffected.
8. **Given** the same triggering event delivered more than once (e.g., a redelivered or retried message), **When** the notification system processes it, **Then** the recipient still sees exactly one notification, receives one in-app push, and is emailed at most once.
9. **Given** a bulk operation that produces many same-category events in a short window (e.g., a batch of ingestions completing), **When** they are delivered, **Then** the recipient receives a coalesced digest or rate-limited summary rather than one in-app push and one email per event.

---

### Edge Cases

- **Provider outage**: When a primary AI provider times out, returns a server error, or is rate-limited, the system fails over to a fallback provider (capped at one hop) for generation/captioning; it does not fail over on merely "low-quality" output.
- **Embedding-provider outage during ingestion**: Content cannot be re-embedded with a different model into the same index; affected items are parked for retry rather than embedded inconsistently.
- **Cross-clearance cache safety**: The same question asked by two members with different clearance must never return one member's higher-clearance answer to the other. Any cached answer is keyed by workspace + requester clearance + the authorized document set and is reused only when the requester's authorization scope is identical.
- **Redis/hot-state loss**: If the hot credit balance is lost, it is rebuilt from the durable ledger before serving; periodic reconciliation corrects any drift.
- **Stale long-horizon worker**: A task whose worker stops sending heartbeats is automatically re-queued rather than abandoned.
- **Abandoned approval gate**: A human-in-the-loop gate that is never resolved (the member walks away, or its expiry elapses) fails closed — the gated action never runs, no credits are spent, and a paused long-horizon run does not silently resume; the pending gate is auto-expired by a scheduled sweep (FR-040, SC-014).
- **Unsupported ingestion type (video/audio)**: Accepted at the boundary but clearly reported as not yet implemented.
- **Oversize upload**: A file exceeding the workspace's per-file size limit (default 50 MB) is rejected at the upload boundary with a clear message before any ingestion or credit spend.
- **Empty or unanswerable query**: When no authorized documents are relevant, the assistant responds that it has no relevant information rather than fabricating an answer or leaking restricted content.
- **Bring-your-own-key agents**: Agents using their own provider keys bypass server-side moderation and token metering; members must explicitly accept this gap at registration, and admins can disable this mode per workspace.
- **Notification recipient scoping**: A notification is delivered only to its intended recipient within the originating workspace; it is never visible to other members or across workspaces, even at higher clearance.
- **Email-provider outage**: A failed email send is retried with backoff and parked in a dead-letter path on exhaustion; the in-app notification is delivered independently and is never blocked by email failure.
- **Duplicate notification event**: A redelivered or retried triggering event (at-least-once transport, producer retry) is de-duplicated by its idempotency key so the recipient never sees a duplicate notification, in-app push, or email.
- **Notification storm**: A burst of same-category events for one recipient (e.g., a batch of ingestions completing) is coalesced into a digest or rate-limited summary rather than flooding the inbox and the email provider.
- **Large broadcast**: An admin broadcast to a large membership fans out asynchronously off the request path, so the admin's request returns promptly and per-recipient delivery (subject to preferences) proceeds in the background.
- **Email bounce/complaint**: A hard bounce or spam complaint suppresses further email to that address rather than retrying indefinitely; in-app delivery is unaffected, and non-essential emails carry an unsubscribe affordance that disables that category's email channel.

## Requirements *(mandatory)*

### Functional Requirements

**Ingestion**

- **FR-001**: System MUST allow authenticated members to ingest PDF, DOCX, markdown/plain-text, and image files, and to create notes. A note carries user-authored body text and optional attached web links. On explicit request (**Enrich**, re-runnable), the system MUST crawl the attached links, distill each page aligned to the note's intent, and present a draft suggestion the member reviews; only the member-accepted note body is indexed, with the crawled sources retained as citation metadata (not separately embedded). Pasting a bare URL with no body MUST create a note whose draft body is the page summary, subject to the same accept gate.
- **FR-002**: System MUST automatically convert ingested content to a searchable form, generate descriptive captions for images/diagrams, and assign auto-taxonomy tags and a summary to each document.
- **FR-003**: System MUST report ingestion progress to the member in real time and clearly indicate when an unsupported source type (e.g., video/audio in Phase 1) cannot be processed. System MUST enforce a per-file size limit that is admin-configurable per workspace (default 50 MB) and reject oversize files at the upload boundary with a clear message before any ingestion or credit spend.
- **FR-004**: System MUST assign each document's security attributes (workspace, owner, tenant, access level) from the authenticated upload context, never from model-inferred content, MUST prevent an uploader from assigning an access level above their own clearance, and MUST default a document's access level to the uploader's own clearance level when none is explicitly chosen. Clearance is a fixed ladder of 5 ordered levels (1–5).
- **FR-005**: System MUST treat any model-suggested sensitivity as advisory only, never as the enforced access level without explicit human confirmation. When a model suggests an access level **above** the uploader's default, applying it MUST go through the human-in-the-loop approval gate (FR-040); absent an approval, the document keeps the uploader's default level.

**Query & AI**

- **FR-006**: System MUST let members ask natural-language questions and receive relevant answers with citations to the contributing source documents.
- **FR-007**: System MUST restrict every query to the member's own documents plus shared workspace documents at or below the member's clearance, enforced at the data layer. Any cached answer or retrieval result MUST be keyed by workspace + requester clearance + authorized document set and reused only for requesters with an identical authorization scope.
- **FR-008**: System MUST answer structured-data questions (e.g., employees, projects, metrics) using fixed, workspace-scoped queries rather than free-form generated database queries.
- **FR-009**: System MUST retain conversational session context so follow-up questions are answered coherently.
- **FR-010**: System MUST screen each user input and short-circuit disallowed content or obvious prompt-injection attempts before performing retrieval or consuming credits, recording the event.
- **FR-011**: System MUST treat all retrieved document content and tool output as untrusted data, never as instructions, and MUST NOT allow injected text to trigger additional tool calls or escalate tool access.
- **FR-012**: In Phase 1, the system MUST expose read-only agent tools (search, lookup, structured queries, utilities) as the default tier, plus a small set of **HITL-gated action tools** (agent web-search and a scoped note-edit, FR-041) that are the *only* agent actions permitted to reach outside the workspace or mutate stored content. Every such action MUST be routed through the human-in-the-loop approval gate (FR-040) — which is the single mechanism that backs every confirmation rather than a per-feature promise — and MUST be access-bounded (an agent acts within the lower of its own and its owner's clearance and may never exceed those bounds). Read-only tools carry no side effects. Note enrichment's crawl remains an internal, member-initiated fetch step (FR-001), never an autonomous agent action. Any state-changing or message-sending action **not** on the Phase-1 action-tool list (broad file writes, document creation, message sending) remains out of scope for Phase 1.

**Workspace & Access Control**

- **FR-013**: System MUST support shared workspaces containing both personal and team knowledge, with each member assigned a role and a clearance level.
- **FR-014**: System MUST enforce complete isolation between workspaces so no content from one workspace is ever visible to another.
- **FR-015**: System MUST allow owners/admins to invite members by email, assign roles and clearance, and revoke invitations or access.

**Credits & Budgets**

- **FR-016**: System MUST deduct credits in real time for each AI operation (ingestion, captioning, querying, reranking) from a shared workspace balance and display the remaining balance to members.
- **FR-017**: System MUST enforce three independent cost ceilings — workspace balance, per-user daily limit, and per-call output cap — and MUST warn the member when usage crosses a warning threshold that is admin-configurable per workspace (default 80% of the workspace balance and per-user daily limit) rather than failing silently.
- **FR-018**: System MUST block AI operations with a clear, actionable message when the balance is exhausted, including an upgrade path.
- **FR-019**: System MUST ensure a retried or duplicated operation is charged at most once, and MUST keep the displayed/hot balance reconciled with a durable record of all credit changes.
- **FR-020**: System MUST apply stricter limits to new/trial accounts and cumulative per-IP ceilings to deter free-credit abuse.

**Observability & Admin**

- **FR-021**: System MUST provide a debug panel that, for each answer, shows detected intent, tool called, index tier, access-filter result, retrieval and rerank scores, chunk expansion, injected memory, model used, token cost, and credits deducted, with a link to the full trace.
- **FR-022**: System MUST provide an admin dashboard showing per-user and per-feature AI usage and cost, and allow admins to manage member limits.
- **FR-023**: System MUST record an audit trail of AI tool calls (tool, role, cost, result fingerprint, trace reference) and of workspace/member actions.
- **FR-024**: System MUST scrub personally identifiable information from prompts/responses before they are written to trace or evaluation stores, and MUST retain full prompt/response bodies only for a 30-day window, after which raw bodies are purged and only metadata, hashes, and aggregates are kept long-term.

**Local Agents (optional)**

- **FR-025**: System MUST allow members to optionally register a local agent scoped to a user and workspace, with revocable device credentials, while ensuring all core features work fully without any agent.
- **FR-026**: System MUST, by default, route a local agent's AI calls through the server so usage is metered, budgeted, and audited; a bring-your-own-key mode MAY bypass server metering for AI tokens but MUST still route workspace tool calls through the server, and admins MUST be able to disable this mode per workspace.
- **FR-027**: System MUST treat all agent results as untrusted, validating tool arguments against the device's authorized workspace scope.
- **FR-028**: System MUST persist long-horizon tasks durably so they resume after worker interruption, support cancellation, and enforce a hard per-task cost cap independent of daily budgets.

**Reliability**

- **FR-029**: System MUST fail over to a fallback AI provider on timeout, server error, or rate-limit (capped at one hop), but never on low-quality output, and MUST make provider fallbacks observable.
- **FR-030**: System MUST ship a minimal evaluation seed set (prompt examples and a golden retrieval set) used as a regression tripwire, including a hard assertion that a query never returns a document above the requester's clearance.
- **FR-031**: After delivering an answer, the system MUST generate 2–3 suggested follow-up questions derived from the answer context and the retrieved sources. Suggestions MUST be scoped to the member's clearance (never hint at inaccessible content), rendered as clickable chips below the answer, and clicking a chip MUST populate and submit the composer with that question. Suggestions MUST NOT be generated when the answer was refused (injection-blocked) or when zero sources were retrieved.

**Notifications**

- **FR-032**: System MUST generate a notification for each of the following recipient-scoped events: ingestion completed, ingestion failed, workspace invite received/accepted/revoked, credit near-limit warning, credit balance exhausted, long-horizon task halted at its cost cap, a **human-in-the-loop approval awaiting the member** (an agent action or long-horizon step paused for their decision, FR-040/FR-041), document shared with the member, member clearance changed, new member joined (admin recipients), and admin broadcast. Each notification MUST carry a category, priority, human-readable title/body, and a payload referencing the originating resource for deep-linking. Each notification-generating event MUST carry an idempotency key derived from the originating resource and event so that a redelivered or retried event produces at most one persisted notification, one in-app push, and one email per recipient.
- **FR-033**: System MUST persist notifications in a recipient-scoped inbox, expose an unread count, and let members mark notifications read individually and all-at-once; read state MUST persist durably.
- **FR-034**: System MUST deliver in-app notifications to the recipient in real time over the existing streaming channel, updating the unread count without a page reload.
- **FR-035**: System MUST let each member configure delivery per category and per channel (in-app and email) independently; when a category's channel is disabled, the system MUST NOT deliver that category over that channel. Email delivery MUST go through a provider-agnostic interface and MUST retry transient failures, parking exhausted sends in a dead-letter path rather than dropping them silently. Every non-essential notification email MUST include an unsubscribe affordance that disables that category's email channel, and the system MUST honor provider bounce/complaint signals by suppressing further email to a hard-bouncing or complaining address rather than repeatedly retrying it.
- **FR-036**: System MUST scope every notification strictly to its intended recipient within the originating workspace, enforced at the data layer; a notification MUST never be visible or delivered to another member or across workspaces, regardless of clearance.
- **FR-037**: System MUST allow a workspace admin to send a broadcast announcement to all current members of that workspace, subject to each member's per-channel preferences, and MUST record the broadcast in the audit trail. Broadcast fan-out MUST execute asynchronously (off the request path) so that delivery to a large membership neither blocks nor times out the admin's request.
- **FR-038**: System MUST protect recipients from notification storms by coalescing high-volume same-category events (e.g., many documents finishing ingestion in a short window) into a digest or rate-limited summary rather than one in-app push and one email per event, while still recording the underlying activity.
- **FR-039**: System MUST bound notification storage growth with a documented retention policy that archives or purges old read notifications, so the inbox and unread-count queries remain performant over time.

**Human-in-the-Loop Approval**

- **FR-040**: System MUST gate every action that (a) mutates the knowledge index, (b) applies a model-suggested security attribute above the uploader's default, or (c) reaches outside the workspace, on an **explicit human approval that is recorded durably before the action runs and before any credit is spent**. A gated action that is pending approval MUST consume zero credits and perform no side effect on its subject; an unresolved, rejected, or timed-out gate MUST fail closed (the action never proceeds — no auto-approve). An approval MUST be resolvable only by an authorized approver within the originating workspace, and every resolution MUST be audited. The human decision (and any edited value it carries) MUST originate from the approver and MUST NOT be derived from model, tool, or document output. The Phase-1 gated actions are: note-enrichment **index-on-accept** (FR-001), a **paused long-horizon agent step** (FR-028), applying a **model-suggested access level** above the uploader default (FR-005), an agent **web-search** before each fetch (FR-041), and an agent **note-edit** before each commit (FR-041). A paused long-horizon run MUST resume exactly once from its checkpoint on approval, without re-spending credits already settled (SC-009, SC-014). This mechanism is specified as a reusable port in [contracts/approval-ports.md](./contracts/approval-ports.md).

**Agent Action Tools (HITL-gated)**

- **FR-041**: In Phase 1 the system MUST provide two agent **action** tools beyond read-only retrieval, each gated by the human-in-the-loop approval mechanism (FR-040) and access-bounded: (a) an agent-initiated **web-search** (available to `user` and `admin` roles) that reaches outside the workspace for fresh/time-sensitive information, requiring explicit human confirmation **before each fetch**; and (b) a scoped **note-edit** that modifies an **existing** note document, requiring explicit human approval **before the change commits**. Both run in the durable (long-horizon) execution form so the approval can pause and resume the run; the interactive query form remains read-only and never pauses. A note-edit MUST be permitted only for the agent's owner's own personal notes or shared workspace notes at or below the agent's effective clearance (`min(agent, owner)`), MUST NOT raise a note's access level above the floor derived from its sources (the write envelope), and MUST NOT create new documents (creation remains a member action so security attributes come from the authenticated context, FR-004). Both tools are **off by default per role** (`agent_policies`) and admin-disablable per workspace. Web crawling used by web-search reuses the same SSRF-guarded fetch as note enrichment (FR-001).

- **FR-042** *(document-scoped question)*: System MUST let a member scope a question to one or more **specific documents** they are authorized to read, so "summarize this" and "what does this contract say about termination" answer from the named sources instead of the whole workspace. Scoping narrows the retrieval set; it never widens authorization — a document the member could not otherwise read is not readable by naming it, and an unauthorized or non-existent id is reported as **not found**, never as forbidden, so document existence stays unprobeable (FR-007, SC-001). A scoped question is metered and audited exactly like any other query.
- **FR-043** *(attach a file in the conversation)*: System MUST let a member attach a file directly in the chat composer and ask about it in the same turn. An attachment is **ingested as a normal document into the member's personal scope** — private to the uploader, retained and browsable in the library, and deletable like any other document — never a hidden or untracked copy. It is metered as an ingestion (conversion + embedding) in addition to the query it accompanies, so an attachment never produces unbilled compute. The turn that carries the attachment is automatically scoped to it (FR-042). The member MUST be told, before sending, that the file is saved to their library — an attachment that silently becomes permanent workspace content would misrepresent what the system retains. Supported types and the oversize/unsupported rules are exactly those of library ingestion (FR-003); nothing is accepted in chat that would be refused in the library.
- **FR-044** *(asking about images)*: System MUST answer questions about image content using a **multimodal model call at query time**, not only the caption generated at ingestion. Captions remain the retrieval surface (they are what makes an image findable by text search, FR-002); the vision call is what answers about content the caption did not anticipate. Image bytes crossing to the model MUST be treated as **untrusted input** on the same footing as retrieved documents: text rendered inside an image is a prompt-injection vector that the text-only moderation gate cannot see, so instructions recovered from an image MUST NOT be executed as directives (FR-011). Vision calls are metered on their real token cost and MUST fail closed to the caption-only answer, never silently answer from the caption while implying the image was examined.

- **FR-045** *(ask before guessing, when it matters)*: When a question is ambiguous in a way that would **materially change the answer**, the system MUST ask the member which reading they meant instead of silently choosing one — presenting 2–4 concrete options plus an always-available free-text reply, and never a fixed menu the member cannot escape. The clarification **is** that turn's response: the run ends there, and the member's selection (or typed reply) begins a normal follow-up query with the conversation's context intact — no run is held open and no credits are held pending. Asking MUST be the exception, not the default: when the ambiguity is immaterial, or one reading is clearly dominant, the system MUST answer with the best interpretation and **state the assumption it made** rather than either guessing silently or interrogating the member. A clarification turn is metered like any other generation — it performs real inference and must not become an unbilled path — and MUST be visually distinct from post-answer follow-up suggestions (FR-031), which are optional and non-blocking.

### Key Entities *(include if feature involves data)*

- **User**: A person with credentials and, within a workspace, a role and clearance level.
- **Workspace**: A shared tenant boundary owning members, knowledge, credits, and policies; the unit of isolation.
- **Workspace Member**: The association of a user to a workspace, carrying role, clearance/access level, and status.
- **Invite**: A pending, revocable invitation to join a workspace with a designated role/clearance.
- **Document**: An ingested unit of knowledge with owner, workspace, source type, tags, summary, access level, and a personal-vs-workspace scope.
- **Chat Session**: A member's conversational thread with remembered context.
- **Credit Balance & Ledger**: The workspace's current spendable credits plus a durable, append-only record of every credit change.
- **AI Operation Record**: A log of each metered AI call — feature, model, provider, token counts, cost, and trace reference.
- **Agent Policy**: Per-role rules governing allowed tools, daily token budget, and audit hooks.
- **Audit Record**: An append-only entry capturing AI tool calls and workspace/member actions with a tamper-evident fingerprint.
- **Connected Device**: A registered local agent with type, billing mode, scope, and revocable credentials.
- **Long-Horizon Task Run**: A durable record of a multi-step agent task with status, checkpoint state, per-task cost cap, and spend.
- **Approval Request**: A durable, recipient-scoped record of a pending or resolved human-in-the-loop gate — its kind (enrich-accept, long-horizon step, sensitivity confirm), a reference to the subject it guards, the payload describing what is being approved, and the human decision (approve/reject/edit) with resolver and timestamp. It is the durable backing of the approval mechanism (FR-040); `agent_run.status='paused'` and a note's `drafted` state both reference a pending row.
- **Structured Records**: Workspace-scoped operational data (employees, projects, metrics) answerable via fixed tools.
- **Sandbox Run Record**: An audit entry for one isolated execution of untrusted content (link crawl, document conversion) — template, feature, exit status, consumed compute, egress volume, timeout flag, and a result fingerprint. It carries no file or content bodies, mirroring the no-body rule of the AI Operation Record. Present because isolated execution is metered and audited like any other AI operation (FR-023, FR-024); see Assumptions — *Isolated execution*.
- **Notification**: A recipient-scoped, persisted record of a workspace event — category, priority, title, body, resource-reference payload, idempotency key (for de-duplicating redelivered events), and read state — surfaced in the in-app inbox and optionally by email, and subject to a retention policy.
- **Notification Preference**: A member's per-category, per-channel (in-app / email) delivery choice within a workspace.
- **Email Suppression**: A per-address record marking an email address as suppressed after a hard bounce or spam complaint, so the system stops sending email to it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% access-control correctness — across all queries, a member never receives, cites, or is influenced by a document above their clearance or outside their workspace (hard requirement; any violation is a release blocker).
- **SC-002**: For the golden knowledge set, at least 85% of questions surface the correct source among the top results before final ranking, and at least 80% after final ranking.
- **SC-003**: The most relevant source for a question ranks among the top results with a mean reciprocal rank of at least 0.70 on the golden set.
- **SC-004**: A member can go from first upload to a cited answer about that content within a single short session (target: under 5 minutes for a typical document).
- **SC-005**: Every answer is accompanied by an observable trace of all retrieval and generation steps, including credits deducted, with no step hidden from the debug panel.
- **SC-006**: Credit accounting is exact — no AI operation is double-charged on retry/duplicate submission, and the displayed balance reconciles to the durable ledger within tolerance on every reconciliation cycle.
- **SC-007**: Disallowed or injection inputs are refused before any retrieval or credit spend in 100% of seeded injection-canary cases.
- **SC-008**: All core capabilities (ingest, query, library, workspace, credits, debug panel) function with zero local agents connected.
- **SC-009**: An interrupted long-horizon task resumes and completes (or is cleanly cancelled) without loss, and never exceeds its per-task cost cap.
- **SC-010**: Near-limit usage produces a member-visible warning at the configured threshold (admin-configurable per workspace, default 80%), and exhaustion produces a clear actionable message rather than a silent failure, in 100% of cases.
- **SC-011**: A notification for a triggering event reaches the recipient's connected in-app inbox in near real time (target: under 5 seconds at p95), and the unread count reflects it without a page reload.
- **SC-012**: 100% recipient-scoping correctness — across all generated notifications, a notification is never delivered to or visible by any member other than its intended recipient, nor across workspaces (hard requirement; any violation is a release blocker).
- **SC-013**: Exactly-once recipient delivery — a triggering event delivered more than once (redelivery or producer retry) yields at most one persisted notification, one in-app push, and one email per recipient in 100% of duplicate-event cases.
- **SC-014**: 100% of gated actions record a human decision before proceeding — a pending or rejected gate spends zero credits and never mutates the index or reaches outside the workspace; a paused long-horizon run resumes exactly once on approval without re-spending settled credits (parity with SC-009); and an approval is never visible to or resolvable by anyone other than an authorized approver within the originating workspace (hard requirement; any recipient-scoping violation is a release blocker).
- **SC-015**: 100% agent-write correctness — an agent note-edit never modifies a note outside its `min(agent, owner)` clearance or workspace, never raises a note's access level above the floor derived from its sources, and never creates a document; every applied edit carries a recorded human approval. Any violation is a release blocker (parity with SC-001).
- **SC-017**: Clarification is **rare and useful**, measured on the golden query set (FR-030): the system requests clarification on **≤ 10%** of queries — over-asking is a failure mode as real as guessing wrong, and an agent that interrogates the member on routine questions has degraded the product — and when it does ask, the clarified follow-up produces a correct, cited answer at least as often as the unclarified baseline. Every clarification offers a free-text path, so a member is never trapped in a menu that omits what they meant.
- **SC-016**: A member can attach a file in chat and receive a grounded answer about it **without leaving the conversation**, and the attachment is accounted for end to end: it appears in that member's personal library, is never visible to another member, and its conversion + embedding are billed as an ingestion that reconciles to the ledger like any other (parity with SC-006). Scoping a question to documents **never** returns content the member could not already read, and naming an unauthorized document id is indistinguishable from naming one that does not exist (parity with SC-001, release blocker).

## Assumptions

- **Phase scope**: Only Phase 1 (Core App) is in scope. Video/audio ingestion, payment/subscription UI, infographic/mind-map generation, agent file-edit actions, the full evaluation suite, and automated security red-teaming are deferred; structural prompt-injection defenses and a minimal evaluation seed set are included in Phase 1.
- **Audience**: The primary audience is a developer/hiring showcase, so every architectural pattern must be observable and named in the UI.
- **Authentication**: A standard authenticated session model is assumed; identity, workspaces, and invitations reuse the existing SaaS kernel.
- **Clearance model**: Access is governed by a fixed ladder of 5 ordered numeric clearance levels (1–5); a member sees documents at or below their level plus their own personal documents. A new document with no explicitly chosen access level defaults to the uploader's own clearance level. **Terminology**: a *user/member* carries a **clearance level**; a *document* carries an **access level**; a member may see a document when its `access_level` ≤ the member's clearance (referred to as `effective_access_level` in retrieval and the MCP contracts). These three names denote the same 1–5 ladder.
- **Credit pricing**: Credits are priced proportionally to real AI cost with a margin; exact per-operation credit costs follow the documented pricing table and may be tuned without changing behavior.
- **Connectivity**: Members have stable internet connectivity; large file uploads go directly to object storage via the application. Individual files are bounded by an admin-configurable per-file size limit per workspace (default 50 MB).
- **Demo data**: New workspaces may be seeded with demo knowledge and structured records to demonstrate capabilities.
- **Local agents**: Local agents are optional and additive; supported agent types are those offering a configurable AI base URL and/or tool-protocol client support, with bring-your-own-key as the fallback integration mode.
- **Retention**: Raw prompt/response bodies are retained for a 30-day window for replay; after 30 days they are purged and long-term storage keeps metadata, hashes, and aggregates, with PII scrubbed before write.
- **Isolated execution**: Processing untrusted external content — crawling a link (FR-001) and parsing an uploaded file (FR-002) — runs inside a hardware-isolated, egress-restricted sandbox rather than in the shared application process. This is an **implementation strategy for existing requirements, not a requirement of its own**: it carries no FR because it adds no user-visible behavior; it is how FR-001/FR-002 are executed safely and how FR-023/FR-024's audit-and-meter obligations extend to that execution. The choice of sandbox technology is swappable and deployment-specific; environments without hardware virtualization fall back to a weaker container isolation without changing any behavior in this spec. Rationale and the rejected alternatives are recorded in [research.md §24](./research.md); the port is specified in [contracts/sandbox-runtime.md](./contracts/sandbox-runtime.md).

## Out of Scope (Phase 1)

- Video and audio ingestion (boundary stub only)
- Subscription/payment user interface and provider checkout
- Infographic and mind-map generation
- Agent message-sending and broad file/document writes — creating new documents, artifact writes, `write_memory`, and any write beyond the narrow, HITL-gated, access-bounded **note-edit** (FR-041). Phase 1 permits *only* the scoped note-edit and the agent web-search as agent actions; all other state-changing/message-sending agent actions are Phase 2.
- Full evaluation tooling and automated security red-team scanning
- High-concurrency scale-out & resilience hardening (worker autoscaling, SSE connection ceilings, connection pooling, Qdrant/Redis HA, load testing) — deferred to **Phase 4**; see [draft-plan.md — Phase 4](../draft-plan.md#phase-4-scalability-and-resilience-hardening)
- Per-answer thumbs up/down rating and the workspace satisfaction metric — **Phase 2**; see [draft-plan.md — AI Response Rating](../draft-plan.md#phase-2--ai-response-rating-thumbs-up--down)
- Typed artifacts, the knowledge graph (`knowledge_edges`), the agent registry, and external connectors (Git/Jira/Confluence) — **Phase 2**; see [draft-plan.md — Enterprise Knowledge Layer](../draft-plan.md#phase-2--enterprise-knowledge-layer-typed-artifacts-knowledge-graph--agent-context-api)
- **A second access axis.** Phase 1 access control is the L1–L5 clearance ladder plus personal scope, and that is the whole model. Group/principal ACLs (`allowed_principals`), configurable clearance labels, and delegated group administration are **Phase 2**; see [draft-plan.md — Access model (decided)](../draft-plan.md#access-model-decided). Phase 1 stores `access_level` as an integer and never persists a level *name*, so adding labels later is a display change only.
- An `organization` above Workspace (consolidated billing, org-wide SSO/SCIM, policy defaults) — **Phase 2**; Phase 1 treats Workspace as both the isolation boundary and the billing entity. See [draft-plan.md — Tenancy & Delegated Administration](../draft-plan.md#phase-2--tenancy--delegated-administration)
- Agents as independent principals (own clearance/groups bounded by their owner) and the **broad** agent write scope (arbitrary `write_ops`, `write_artifact_types`, `writable_principals`, document creation), plus resource-level (`operation` + `resource_id`) audit rows — **Phase 2**; see [draft-plan.md — Agent Access & Accountability](../draft-plan.md#phase-2--agent-access--accountability). Phase 1 agents act with their registering member's access; agent tools are read-only **except** the two HITL-gated action tools (web-search, scoped note-edit) of FR-041, whose write is bounded to `note_update` on existing notes within `min(agent, owner)` clearance.
