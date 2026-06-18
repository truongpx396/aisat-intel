# Feature Specification: AISAT-STUDIO MVP — AI-Powered Shared Second Brain (Phase 1)

**Feature Branch**: `001-contextengine-mvp`

**Created**: 2026-06-05

**Status**: Draft

**Input**: User description: "pls refer to content of draft-idea.md" — AISAT-STUDIO MVP, Phase 1 Core App design spec.

## Overview

AISAT-STUDIO is an AI-powered shared second brain for work teams. Members upload files, paste links, and add notes; the system automatically ingests, organizes, and makes that knowledge queryable through a conversational AI interface. The AI only ever surfaces knowledge the requester is authorized to see, with access control enforced at the data layer rather than by prompt instructions.

This specification covers **Phase 1 (Core App)** only. The Evaluation Suite (Phase 2) and automated security red-teaming (Phase 3) are out of scope, except for a minimal evaluation seed set and the structural prompt-injection defenses that must ship in Phase 1 because untrusted content flows through the core data path.

## Clarifications

### Session 2026-06-05

- Q: How many clearance levels exist and what access level do new documents get by default? → A: Fixed ladder of 5 ordered levels (1–5); a new document defaults to the uploader's own clearance level when none is chosen.
- Q: How must cached answers be scoped so a higher-clearance answer never leaks to a lower-clearance member? → A: Any cached answer is keyed by workspace + requester clearance + the authorized document set, and is reused only for requesters whose authorization scope is identical.
- Q: At what usage level should the near-limit warning fire? → A: An admin-configurable threshold per workspace, defaulting to 80% of the workspace balance and per-user daily limit.
- Q: What is the maximum per-file size for ingestion? → A: An admin-configurable per-file size limit per workspace, defaulting to 50 MB; oversize files are rejected at the boundary with a clear message.
- Q: How long are raw prompt/response bodies retained before only metadata/aggregates remain? → A: 30 days, after which raw bodies are purged and only PII-scrubbed metadata, hashes, and aggregates are kept.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ingest knowledge into a searchable library (Priority: P1)

A team member uploads documents (PDF, DOCX, markdown/plain text, images) or pastes a web link. The system converts, organizes, auto-tags, and indexes the content, then shows real-time ingestion progress. Once complete, the content is queryable and browsable in the library.

**Why this priority**: Nothing else in the product delivers value without knowledge in the system. Ingestion is the foundational entry point and the first thing a new user does.

**Independent Test**: Upload a PDF and paste a URL, observe progress to completion, and confirm both items appear in the library with auto-generated tags and a summary — without using any query or team features.

**Acceptance Scenarios**:

1. **Given** an authenticated member with available credits, **When** they upload a supported file (PDF/DOCX/markdown/image), **Then** the system ingests it, assigns auto-taxonomy tags and a summary, and reports completion via live status.
2. **Given** an authenticated member, **When** they paste a web link, **Then** the system crawls the page, converts it to text, ingests it, and surfaces it in the library.
3. **Given** an uploaded image or diagram, **When** ingestion runs, **Then** a text caption describing the image is generated and stored alongside it.
4. **Given** an unsupported source type (e.g., video/audio in Phase 1), **When** a member attempts to ingest it, **Then** the system clearly indicates the type is not yet supported rather than failing silently.
5. **Given** a file larger than the workspace's per-file size limit (default 50 MB), **When** a member attempts to upload it, **Then** the system rejects it at the boundary with a clear over-size message rather than failing silently.
6. **Given** an upload, **When** the member chooses an access level no higher than their own clearance, **Then** the document is stored at that level; absent a choice, the document defaults to the uploader's own clearance level.

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
4. **Given** a structured-data question (e.g., about employees, projects, or metrics), **When** asked, **Then** the assistant answers from the structured data source scoped to the workspace.
5. **Given** input that is disallowed or an obvious prompt-injection attempt, **When** submitted, **Then** the system refuses before performing retrieval or consuming credits, and records the event.
6. **Given** a document containing embedded instructions ("ignore previous instructions…"), **When** that document is retrieved as context, **Then** the assistant treats it as reference material and does not follow instructions found inside it.

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

---

### Edge Cases

- **Provider outage**: When a primary AI provider times out, returns a server error, or is rate-limited, the system fails over to a fallback provider (capped at one hop) for generation/captioning; it does not fail over on merely "low-quality" output.
- **Embedding-provider outage during ingestion**: Content cannot be re-embedded with a different model into the same index; affected items are parked for retry rather than embedded inconsistently.
- **Cross-clearance cache safety**: The same question asked by two members with different clearance must never return one member's higher-clearance answer to the other. Any cached answer is keyed by workspace + requester clearance + the authorized document set and is reused only when the requester's authorization scope is identical.
- **Redis/hot-state loss**: If the hot credit balance is lost, it is rebuilt from the durable ledger before serving; periodic reconciliation corrects any drift.
- **Stale long-horizon worker**: A task whose worker stops sending heartbeats is automatically re-queued rather than abandoned.
- **Unsupported ingestion type (video/audio)**: Accepted at the boundary but clearly reported as not yet implemented.
- **Oversize upload**: A file exceeding the workspace's per-file size limit (default 50 MB) is rejected at the upload boundary with a clear message before any ingestion or credit spend.
- **Empty or unanswerable query**: When no authorized documents are relevant, the assistant responds that it has no relevant information rather than fabricating an answer or leaking restricted content.
- **Bring-your-own-key agents**: Agents using their own provider keys bypass server-side moderation and token metering; members must explicitly accept this gap at registration, and admins can disable this mode per workspace.
- **Notification recipient scoping**: A notification is delivered only to its intended recipient within the originating workspace; it is never visible to other members or across workspaces, even at higher clearance.
- **Email-provider outage**: A failed email send is retried with backoff and parked in a dead-letter path on exhaustion; the in-app notification is delivered independently and is never blocked by email failure.

## Requirements *(mandatory)*

### Functional Requirements

**Ingestion**

- **FR-001**: System MUST allow authenticated members to ingest PDF, DOCX, markdown/plain-text, and image files, and to ingest web pages from pasted links.
- **FR-002**: System MUST automatically convert ingested content to a searchable form, generate descriptive captions for images/diagrams, and assign auto-taxonomy tags and a summary to each document.
- **FR-003**: System MUST report ingestion progress to the member in real time and clearly indicate when an unsupported source type (e.g., video/audio in Phase 1) cannot be processed. System MUST enforce a per-file size limit that is admin-configurable per workspace (default 50 MB) and reject oversize files at the upload boundary with a clear message before any ingestion or credit spend.
- **FR-004**: System MUST assign each document's security attributes (workspace, owner, tenant, access level) from the authenticated upload context, never from model-inferred content, MUST prevent an uploader from assigning an access level above their own clearance, and MUST default a document's access level to the uploader's own clearance level when none is explicitly chosen. Clearance is a fixed ladder of 5 ordered levels (1–5).
- **FR-005**: System MUST treat any model-suggested sensitivity as advisory only, never as the enforced access level without explicit human confirmation.

**Query & AI**

- **FR-006**: System MUST let members ask natural-language questions and receive relevant answers with citations to the contributing source documents.
- **FR-007**: System MUST restrict every query to the member's own documents plus shared workspace documents at or below the member's clearance, enforced at the data layer. Any cached answer or retrieval result MUST be keyed by workspace + requester clearance + authorized document set and reused only for requesters with an identical authorization scope.
- **FR-008**: System MUST answer structured-data questions (e.g., employees, projects, metrics) using fixed, workspace-scoped queries rather than free-form generated database queries.
- **FR-009**: System MUST retain conversational session context so follow-up questions are answered coherently.
- **FR-010**: System MUST screen each user input and short-circuit disallowed content or obvious prompt-injection attempts before performing retrieval or consuming credits, recording the event.
- **FR-011**: System MUST treat all retrieved document content and tool output as untrusted data, never as instructions, and MUST NOT allow injected text to trigger additional tool calls or escalate tool access.
- **FR-012**: In Phase 1, the system MUST expose only read-only tools (search, lookup, structured queries, utilities); the sole exception is a crawl utility that fetches an external page and enqueues it for ingestion into the caller's own workspace (no mutation of existing knowledge, no outbound message), which MUST be role-gated. Any future state-changing or message-sending action MUST require explicit human confirmation.

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

- **FR-032**: System MUST generate a notification for each of the following recipient-scoped events: ingestion completed, ingestion failed, workspace invite received/accepted/revoked, credit near-limit warning, credit balance exhausted, long-horizon task halted at its cost cap, document shared with the member, member clearance changed, new member joined (admin recipients), and admin broadcast. Each notification MUST carry a category, priority, human-readable title/body, and a payload referencing the originating resource for deep-linking.
- **FR-033**: System MUST persist notifications in a recipient-scoped inbox, expose an unread count, and let members mark notifications read individually and all-at-once; read state MUST persist durably.
- **FR-034**: System MUST deliver in-app notifications to the recipient in real time over the existing streaming channel, updating the unread count without a page reload.
- **FR-035**: System MUST let each member configure delivery per category and per channel (in-app and email) independently; when a category's channel is disabled, the system MUST NOT deliver that category over that channel. Email delivery MUST go through a provider-agnostic interface and MUST retry transient failures, parking exhausted sends in a dead-letter path rather than dropping them silently.
- **FR-036**: System MUST scope every notification strictly to its intended recipient within the originating workspace, enforced at the data layer; a notification MUST never be visible or delivered to another member or across workspaces, regardless of clearance.
- **FR-037**: System MUST allow a workspace admin to send a broadcast announcement to all current members of that workspace, subject to each member's per-channel preferences, and MUST record the broadcast in the audit trail.

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
- **Structured Records**: Workspace-scoped operational data (employees, projects, metrics) answerable via fixed tools.
- **Notification**: A recipient-scoped, persisted record of a workspace event — category, priority, title, body, resource-reference payload, and read state — surfaced in the in-app inbox and optionally by email.
- **Notification Preference**: A member's per-category, per-channel (in-app / email) delivery choice within a workspace.

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

## Out of Scope (Phase 1)

- Video and audio ingestion (boundary stub only)
- Subscription/payment user interface and provider checkout
- Infographic and mind-map generation
- Agent actions that modify files or send messages
- Full evaluation tooling and automated security red-team scanning
