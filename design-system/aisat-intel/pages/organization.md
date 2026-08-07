# Page Override: Organization (Tenancy, Billing, Identity, Policy)

> Overrides `../MASTER.md` for the Organization screen. **Phase 2** — see
> [specs/draft-plan.md](../../../specs/draft-plan.md) "Phase 2 — Tenancy & Delegated
> Administration". No Phase-1 functional requirement maps to this screen.

## Purpose
The administrative and billing container above Workspace: which workspaces exist, one
contract and one credit pool for all of them, one identity connection, and policy
defaults set once. It is deliberately **not** a knowledge surface — no document, chunk,
edge or search result appears here.

## Reachability — deliberately not a nav item
Every workspace belongs to exactly one organization, but for a small customer the org is
auto-created at signup and never surfaced. It appears only when the org has more than one
workspace or an enterprise plan, and is reached from the **workspace switcher** in the
sidebar (which then shows the org name above the workspace name), not from a permanent
nav entry. A ten-person team should never see the word "organization"; adding a
sidebar item for them would be exactly the ceremony this design avoids.

## Layout
- App shell. The sidebar switcher is highlighted instead of a nav item, because this
  screen is org-scoped rather than workspace-scoped.
- Header: org name + `Organization` pill + tabs **Workspaces · Billing · Identity ·
  Policy** + the viewer's org role.
- A standing notice above all tabs (see below).

## The standing notice (required on every tab)
**Organization roles are administrative reach, never content reach.** An org admin can
create workspaces, manage members, connect the IdP and pay the bill — and cannot read a
single document in any workspace without separate membership there. This is the same
no-implicit-read rule that governs workspace admins and group owners, applied one level
up. It must be visible on this screen, because an org-admin surface is precisely where a
reader would otherwise assume the opposite.

## Workspaces tab
- **Workspace table**: name, *why separate* (client isolation / pre-close M&A / data
  residency), members, documents, credit allocation with a usage meter, and Manage.
- **Guidance callout — the most important content on this screen**: *a workspace is a
  knowledge domain, not an org-chart node.* Most organizations should run **one**
  workspace and separate access with clearance and groups. Telling customers to make a
  workspace per department manufactures a fragmentation problem that then demands
  cross-workspace search to undo. The "why separate" column exists to make an
  unjustified workspace look conspicuous.

## Billing tab
- **Organization pool**: purchased credits, amount allocated to workspaces, unallocated
  remainder. Note that "left unspent" and "left un-allocated" are **two different
  numbers** answering two different questions ("will we run out?" and "can I raise a
  workspace's allocation?"), and both are shown. Collapsing them into one figure is how
  an earlier draft produced an unallocated total that double-counted consumption.
- **Current plan**: plan, price, allotment, renewal, billing email, Change plan, provider
  portal link.

### Plan catalogue — the surface `Change plan` opens
> This is the screen [credits.md](./credits.md) delegates to when it says the plan
> catalogue "moved to organization.md". That handoff was previously dropped: this file
> listed **Change plan** as a control but never specified what it opened, so the button
> existed in the mockup and led nowhere, as did the Credits screen's **Upgrade** and
> **Add credits**. Backed by `GET /billing/plans` → `POST /billing/checkout`
> ([bff-rest.md](../../../specs/001-contextengine-mvp/contracts/bff-rest.md)).

- **Two purchase kinds, deliberately on one screen** (`plans.kind`):
  - **Subscription tiers** answer *"we keep running out"* — a recurring `credit_allotment`.
  - **One-time credit packs** answer *"we are blocked right now"* — a top-up that changes
    neither plan nor renewal, and says so.
  This split drives where the entry points land: the Credits screen's **near-limit**
  banner deep-links to the tier grid, its **exhausted** banner deep-links to the packs
  section. Sending someone blocked mid-task into an annual-commitment decision turns an
  outage into a churn moment.
- **Tier cards**: name, positioning line, price, allotment, workspace count, SSO/SCIM,
  and one action. Prices show a **per-month equivalent** under the yearly toggle — a
  `$1,990` figure next to a `$199` one is not a comparison a reader can perform.
- **Current plan is marked and not purchasable** — its action reads `Your current plan`
  and is inert, never a live button that would no-op.
- **Enterprise carries no checkout affordance.** It is invoiced, so it gets `Contact
  sales`; rendering a disabled buy button for it would imply self-serve that does not exist.
- **Downgrade guard — surfaced before the irreversible step.** A tier whose allotment is
  below the org's *committed allocations* is marked on the card and explained in a
  callout naming the shortfall and the per-workspace commitments. The remedy is **reduce
  allocations first**, never "proceed anyway" — the same fail-closed shape as the
  clearance-level removal guard on the Policy tab, and for the same reason: the silent
  alternative shrinks a workspace's budget without its admin knowing.
- **Role gating is honest, and lives in one place.** Checkout is admin/owner-only
  (`403 forbidden` otherwise). A viewer who cannot buy sees the catalogue with a stated
  reason and a **Request an upgrade from an org admin** action — not a control that fails
  on click. The Credits screen's CTAs deliberately **do not** re-check the role; they
  navigate here, because a second copy of that check is a second place to get it wrong.

### Fulfilment state (required, not optional polish)
Credits are granted on the **verified provider webhook**, never on the redirect back from
checkout. So the return from checkout has a designed state of its own:
- **`processing`** — "Payment processing… credits appear once we verify the provider's
  confirmation", stating that closing the page is safe because the grant is keyed to the
  payment and lands exactly once.
- **`granted`** — the confirmed amount, with the receipt in the table below.

Without this the user returns to a screen still showing the **old balance**, which reads
as a payment that failed — and the natural response to that is to pay again.

- **Never render a granted state optimistically**, and never show provider price/customer
  IDs or any card data.
- **Allocation per workspace**: how the pool is divided, with the rule stated — a
  workspace that exhausts its allocation stops spending and **never silently draws down
  another workspace's budget**.
- **Receipts**: organization-level fiat history. This is the *only* place receipts appear;
  the Credits screen links here rather than duplicating them.

## Identity tab
- **SSO** and **SCIM** connection cards — one connection for the whole organization.
- **Mirrored-vs-directory count** ("14 of 412 mirrored") with the reason stated: only
  groups that actually gate content are mirrored, because a group appearing on no document
  cannot change a search result and would only inflate every query filter.
- **Group registry**, organization-scoped: principal, origin, members, and which
  workspaces use it. A group is a set of *people* (org fact); which documents it gates is
  a workspace fact.

## Policy tab
- **Clearance scheme editor**: level count (2–5) plus per-level label and description.
  State that labels are display-only and never reach the index.
- **Destructive-change warning**: renaming a level is safe; *removing* one requires an
  explicit remap of every document at that level before the change commits — otherwise
  those documents become unreachable or fall to a lower level and widen access silently.
- **Retention** and **defaults for new workspaces**.

## States to show
- Multi-workspace org (as mocked) and the single-workspace case where this screen is
  unreachable from the UI.
- Allocation exhausted in one workspace while the org pool still has credits.
- SCIM connected vs. not connected.
- Plan catalogue seen by an **org admin** (can buy) vs a **workspace admin** (cannot).
- Post-checkout **`processing`** vs **`granted`**.
- A tier that is a valid upgrade vs one blocked by the downgrade guard.

## Don'ts
- Don't show documents, chunks, search results, or any workspace content here.
- Don't imply an org role grants read access to workspace knowledge.
- Don't duplicate receipts or plan controls onto the Credits screen — one billing entity,
  one place to manage it. The Credits CTAs **link** here; they never render a catalogue.
- Don't grant credits on the checkout redirect. The webhook is the fulfilment event; the
  redirect is only navigation.
- Don't offer a downgrade that would silently shrink a workspace's allocation. Block it
  and name the shortfall.
- Don't render a purchase control for someone the server will 403. Say who can buy, and
  give them a way to ask.
- Don't put a disabled buy button on an invoiced plan — that implies self-serve checkout
  that does not exist for it.
- Don't surface the organization at all for a single-workspace customer.
- Don't offer cross-workspace search or a "search all workspaces" affordance. Workspace is
  the isolation boundary; that is the promise the rest of the product is built on.
