# Page Override: Admin Usage Dashboard

> Overrides `../MASTER.md` for the Admin screen. Covers User Story 6 (FR-022) plus
> workspace/member management (FR-013, FR-015), the audit trail (FR-023), and admin
> broadcasts (FR-037).

## Purpose
Workspace operators view per-user and per-feature AI usage and cost, manage member
limits, roles, clearance, and invitations, send broadcast announcements, and review the
audit trail.

## Layout
- App shell; active nav = **Admin**. Tabbed sections: **Usage**, **Members**, **Groups** *(Phase 2)*, **Knowledge** *(Phase 2)*, **Broadcast**, **Audit**.
- Usage tab: KPI cards + per-user table + per-feature breakdown chart.
- Members tab: member table + invite flow.
- Groups tab *(Phase 2)*: group registry, membership administration, break-glass log.
- Knowledge tab *(Phase 2)*: external connectors + the artifact-type taxonomy.
- Broadcast tab: announcement composer + recent broadcasts.
- Audit tab: filterable event log.

## Usage tab
- **KPI cards**: total credits used, active members, avg cost / query, fallback-provider hits, and *(Phase 2)* **answer satisfaction**.
- **Satisfaction card** *(Phase 2)*: `satisfaction_pct` over the period as the headline figure, with the thumbs-up / thumbs-down split and the rated-vs-total answer count beneath it — the denominator matters, because a 100% score over 3 ratings is noise. Sourced from the `response_rating_daily` materialized view (`GET /admin/quality/ratings`), admin-only. When the score falls below the workspace's configured floor (default 80%), an amber banner sits above the KPI row with a **Review disliked answers** action — those turns are the seed corpus for prompt regression tests, so the alert leads somewhere actionable rather than just reporting a number.
- **Per-user table**: member, role, clearance (L1–L5 badge), credits used, daily limit (editable inline), queries, last active. Editing a limit enforces it on subsequent ops (FR-022 scenario 2).
- **Per-feature chart**: stacked bar (ingest / caption / query / rerank) over the period.

## Members tab
- **Member rows**: avatar, name/email, role (Owner/Admin/Member), clearance badge, status.
- **Invite by email** (FR-015): modal with email + role + clearance (clearance ≤ inviter's). Pending invites show a `pending` pill with **Revoke**.
- Sensitive actions (remove member, change role) prompt re-auth (security best practice / AZ6).

## Agent policies (per role)
Admins set the per-role agent policy (`GET|PATCH /admin/policies/{role}`) — the
`allowed_tools` list, daily token budget, and the Phase-1 **write scope**:
- **`can_write` toggle** (off by default) and **`write_ops`** — Phase 1 offers only
  `note_update`, which enables the HITL-gated **`edit_note`** action tool. Show it as a
  clearly-bounded switch, not an open write grant: copy states every edit still needs
  per-commit human approval and is capped at the agent's `min(agent, owner)` clearance and
  the source-derived floor (FR-041, SC-015).
- **`web_search`** enablement for the `user`/`admin` roles (per-fetch human approval).
- Both action tools carry an inline `HITL` marker so the policy never implies an
  unattended capability the server will refuse. The *broad* write scope (create, artifact
  writes, `write_memory`, arbitrary `write_ops`) stays **Phase 2**.

## Groups tab *(Phase 2)*
Administration surface for the second access axis (see
[specs/draft-plan.md](../../../specs/draft-plan.md) "Access model (decided)").
- **Group table**: canonical principal (`group:…` / `ext:<source>:…`), origin pill
  (`native` / `confluence` / `git`), member count, document count, **the admin's own
  membership**, and actions.
- **Native groups** are editable here. **Mirrored groups are read-only** and say where
  they are managed — editing membership locally would silently diverge from the source
  system, which is the exact failure that makes mirrored ACLs untrustworthy.
- **Standing notice**: administering a group is *not* membership of it. An owner or admin
  can grant and revoke without being able to read the documents inside. This has to be
  stated on the screen, because every other tab here works on the opposite assumption
  that admin role implies visibility.
- **Owner column**: native groups show their delegated owner. Ownership is a *grant type*
  (`owner`), not a role, and is recorded separately from membership — most owners hold
  both, but neither implies the other, and an `owner` grant confers **no read access**.
  Mirrored groups show `—`; they have no owner, because membership is source-owned.
- **Join requests**: pending self-service requests routed **to the group's owner, not to
  workspace admins** — that routing is the entire point, since a queue that lands back on
  a central admin has not been delegated. A request against a mirrored group cannot be
  approved here and links out to the source system instead.
- **Per-axis delegation notice**: a group owner manages membership of their own group and
  nothing else. They cannot change clearance — that stays with workspace admins — and
  cannot read the group's documents.
- **Break-glass log**: when, who, which group, the required reason, and expiry (live
  countdown or `expired`). The escape hatch is only defensible because it is visible —
  and the same event also appears in the Audit tab.

## Knowledge tab *(Phase 2)*
Home for external connectors and the typing taxonomy. It sits in Admin — not Library —
because connectors hold secret references and are owner/admin-only.
- **Source cards**, one per connector: kind, sync status pill, target selector
  (repo/space/project), record count, version marker, `default_access_level`, last sync,
  and **Sync now** / **Configure**. Git ships first; unconnected kinds render as a dashed
  placeholder card with a **Connect** action.
- **Fail-closed error state**: a source that cannot map a record's source permissions to a
  workspace principal shows `blocked_acl_unresolved`, names how many records were skipped,
  and says plainly that importing them would widen access silently. The remedy action is
  **Review unmapped groups**, not "import anyway" — there must be no UI path that
  overrides a fail-closed sync.
- **Artifact types table**: type code, whether instances are `governed` by the approval
  lifecycle or inherit their source's state, the **body-indexing policy**
  (`full_body` default, `metadata_only` for large/churny types), and instance count.
- Never render raw connector credentials — the config holds secret refs only.

## Broadcast tab (FR-037)
- **Composer**: title + body fields for an announcement sent to **all current members** of
  this workspace as a `broadcast`-category notification.
- Note that delivery still respects each member's per-channel preferences (a member who
  disabled the broadcast email channel gets it in-app only, etc.).
- **Send** prompts a confirm ("This notifies every current member"); on send, the broadcast
  is recorded in the audit trail.
- **Recent broadcasts** list: title, sender, timestamp, recipient count — read-only.
- Scope is this workspace only; a broadcast never reaches other workspaces.

## Audit tab (FR-023)
- Table: timestamp, actor, **operation** *(Phase 2)*, action/tool, **resource** *(Phase 2)*,
  cost, result fingerprint, trace ref.
- **Operation** is a `create` / `read` / `update` / `delete` pill, colour-coded. **Resource**
  names what was touched and deep-links to it. Without these two columns the trail records
  that something happened but not what it happened *to*, which cannot answer the question an
  agent owner actually asks: "what did my agent change last week?"
- **Agent actors** *(Phase 2)* render with an `agent` pill, the agent name, and its owner —
  an agent is **never** logged as its owner. Actor filter includes each agent.
- **An agent's owner can see their own agent's activity without being a workspace admin.**
  Accountability that requires an admin is accountability nobody exercises.
- Reads are logged at **query granularity, not per chunk** — one retrieval event with counts.
  Per-chunk rows would bury every write in read noise.
- Filters: actor, action type, date range. Monospace for fingerprints/trace refs.
- Note: raw prompt/response bodies retained 30 days, then only metadata/hashes/aggregates (FR-024).

## Don'ts
- Don't allow assigning a clearance/role above the acting admin's own authority.
- Don't surface raw PII in the audit view (scrubbed metadata only).
- Don't let a broadcast cross workspace boundaries or bypass members' per-channel preferences.
- Don't let group administration imply group membership, anywhere in the UI or the API —
  this holds for workspace admins, group owners, and org admins alike.
- Don't route join requests to workspace admins. They go to the group's owner; anything
  else recreates the bottleneck delegation exists to remove.
- Don't allow editing membership of a mirrored group — send the admin to the source system.
- Don't attribute ratings to named members anywhere in the admin UI. Satisfaction is a workspace-level quality signal, not a per-member performance metric — showing "who disliked what" turns honest feedback into a social cost and the signal dies.

---

## Phase 2+ affordances on this screen

| Affordance | Phase | Backing contract |
|---|---|---|
| Satisfaction KPI card + below-threshold alert | 2 | `GET /admin/quality/ratings`; `response_rating_daily` view |
| **Groups** tab — registry, membership, break-glass log | 2 | `principal_groups`, `principal_grants`; Access model (decided) |
| Group ownership + self-service join requests | 2 | `principal_grants.grant_type` ∈ `member` \| `owner`; Tenancy & Delegated Administration |
| Resource-level audit (op + resource + agent actor) | 2 | Agent Access & Accountability, Decision 5 |

A fuller **Quality tab** (per-turn rating browser, disliked-answer triage, eval-run comparison) is deliberately *not* mocked — it depends on the Phase 2 Evaluation Suite, which has no design section in [specs/draft-plan.md](../../../specs/draft-plan.md) yet. The card is the specified slice; build the tab when the eval suite is spec'd.
