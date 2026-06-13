# Page Override: Workspace (Members, Roles, Clearance, Isolation)

> Overrides `../MASTER.md` for the Workspace screen. Covers User Story 3
> (FR-013, FR-014, FR-015) — access-controlled team workspace.

## Purpose
The member-facing view of the shared workspace: who's in it, each member's role and
clearance (L1–L5), how knowledge is split between personal and shared, and the
invite/accept/revoke flow. Reinforces that retrieval/browsing is strictly scoped and
that workspaces are completely isolated from one another.

## Layout
- App shell; active nav = **Workspace**.
- Header strip: workspace identity + an **isolation notice** ("Knowledge here is never
  visible to other workspaces").
- Three zones:
  1. **My clearance card** — the viewer's own role + clearance ladder (L1–L5) with the
     levels they can see highlighted.
  2. **Members panel** — list of members with avatar, role, clearance badge, status.
  3. **Knowledge split** — personal vs shared document counts, and a per-clearance
     breakdown of what the viewer can access.

## Key components
- **Clearance ladder (L1–L5)**: a vertical/stepped indicator. Levels at or below the
  viewer are run-green/active; levels above are locked + muted ("not visible to you").
- **Member row**: name/email, role pill (Owner/Admin/Member), clearance badge, last active.
  Non-admins see this read-only.
- **Invite by email** (FR-015): button → modal with email + role + clearance selector.
  Clearance options are capped at the inviter's own clearance. Pending invites show a
  `pending` pill with **Revoke** (admins only).
- **Isolation banner**: explicit statement that no content crosses workspaces (FR-014).
- **Personal vs shared toggle**: shows counts; shared respects the viewer's clearance.

## States to show
- Viewer as a mid-clearance Member (some levels locked).
- A pending invite awaiting acceptance.

## Don'ts
- Don't let a user assign a role/clearance above their own authority.
- Don't show counts or documents above the viewer's clearance.
- Don't imply any cross-workspace visibility.
