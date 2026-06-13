# Page Override: Admin Usage Dashboard

> Overrides `../MASTER.md` for the Admin screen. Covers User Story 6 (FR-022) plus
> workspace/member management (FR-013, FR-015) and the audit trail (FR-023).

## Purpose
Workspace operators view per-user and per-feature AI usage and cost, manage member
limits, roles, clearance, and invitations, and review the audit trail.

## Layout
- App shell; active nav = **Admin**. Tabbed sections: **Usage**, **Members**, **Audit**.
- Usage tab: KPI cards + per-user table + per-feature breakdown chart.
- Members tab: member table + invite flow.
- Audit tab: filterable event log.

## Usage tab
- **KPI cards**: total credits used, active members, avg cost / query, fallback-provider hits.
- **Per-user table**: member, role, clearance (L1–L5 badge), credits used, daily limit (editable inline), queries, last active. Editing a limit enforces it on subsequent ops (FR-022 scenario 2).
- **Per-feature chart**: stacked bar (ingest / caption / query / rerank) over the period.

## Members tab
- **Member rows**: avatar, name/email, role (Owner/Admin/Member), clearance badge, status.
- **Invite by email** (FR-015): modal with email + role + clearance (clearance ≤ inviter's). Pending invites show a `pending` pill with **Revoke**.
- Sensitive actions (remove member, change role) prompt re-auth (security best practice / AZ6).

## Audit tab (FR-023)
- Table: timestamp, actor, action/tool, role, cost, result fingerprint, trace ref.
- Filters: actor, action type, date range. Monospace for fingerprints/trace refs.
- Note: raw prompt/response bodies retained 30 days, then only metadata/hashes/aggregates (FR-024).

## Don'ts
- Don't allow assigning a clearance/role above the acting admin's own authority.
- Don't surface raw PII in the audit view (scrubbed metadata only).
