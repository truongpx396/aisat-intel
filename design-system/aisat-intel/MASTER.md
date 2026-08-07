# Design System Master File

> **LOGIC:** When building a specific page, first check `design-system/pages/[page-name].md`.
> If that file exists, its rules **override** this Master file.
> If not, strictly follow the rules below.

---

**Project:** AISAT-INTEL
**Generated:** 2026-06-12 14:47:16
**Category:** Developer Tool / IDE

---

## Global Rules

### Color Palette

| Role | Hex | CSS Variable |
|------|-----|--------------|
| Primary (brand) | `#22C55E` | `--color-primary` |
| Background (app canvas) | `#0F172A` | `--color-background` |
| Surface (cards/panels) | `#1E293B` | `--color-surface` |
| Surface elevated (popovers/modals) | `#273449` | `--color-surface-2` |
| Border / divider | `#334155` | `--color-border` |
| Text primary | `#F8FAFC` | `--color-text` |
| Text muted | `#94A3B8` | `--color-text-muted` |
| Text faint (captions) | `#808FA6` | `--color-text-faint` |
| Accent / CTA (run green) | `#22C55E` | `--color-cta` |
| Info (cyan) | `#38BDF8` | `--color-info` |
| Warning (amber) | `#FBBF24` | `--color-warning` |
| Danger (red) | `#EF4444` | `--color-danger` |

**Color Notes:** "Code dark + run green" — a slate-900 canvas with slate-800 elevated surfaces, run-green for primary/success actions, and a small semantic accent set (cyan/amber/red) reserved for status, scores, and credit states. This is a dark-first developer/observability product; there is no light mode in Phase 1.

**Three text steps, and no fourth.** `--color-text` → `--color-text-muted` → `--color-text-faint`. There is no darker step, because there is no darker step that stays legible: the Tailwind slate ramp below this — `slate-500` (3.1:1) and `slate-600` (1.9:1 on `--color-surface`) — fails the 4.5:1 rule outright, and both were in use on real metric captions before being replaced. Reaching past `--color-text-faint` for "even quieter" means the content is either not needed or needs a different treatment (smaller, grouped, behind a disclosure), not a fainter grey.

### Categorical chart ramp (`--color-chart-1…4`)

| Slot | Hue | Value | CSS variable |
|------|-----|-------|--------------|
| 1 | blue | `#3987E5` | `--color-chart-1` |
| 2 | orange | `#D95926` | `--color-chart-2` |
| 3 | violet | `#9085E9` | `--color-chart-3` |
| 4 | magenta | `#D55181` | `--color-chart-4` |

**Encoding identity is a different job from encoding state, and this system needs both on one screen.** The status set (run-green / amber / red / cyan) means *healthy → near-limit → exhausted → informational*, and the Credits screen paints that language on every meter. Using those same hues for chart *series* made amber mean "near limit" in the meter and "Captioning" in the legend six pixels below it. So the categorical ramp is deliberately disjoint from the status set — no green, no amber, no red, no cyan.

Validated as a set against `--color-surface` (worst adjacent CVD ΔE 16.0, worst normal-vision ΔE 19.7, all ≥ 3:1, all inside the dark lightness band). Rules that come with it:

- **Fixed order.** Slot *n* is always the *n*th series. Never cycled, never re-assigned when a filter changes the series count — colour follows the entity, not its rank.
- **Never a 5th generated hue.** Past four series, fold the tail into "Other" or use small multiples.
- **Never a status colour as "series 5"**, and never a categorical colour to mean a state.
- **Identity is never colour-alone** — every series carries its label and value as text.
- Re-validate with the data-viz validator before changing any value; the set passes as a *set*, not per colour.

**Authoring form — channel triplets, not hex.** Each colour above is declared in `:root` as a **space-separated RGB triplet** (`--color-primary-rgb: 34 197 94`) and consumed as `rgb(var(--color-primary-rgb) / <alpha-value>)`. The hex column is the human-readable reference; the triplet is what ships. This is not cosmetic — Tailwind cannot inject an alpha channel into an opaque `var()`, so declaring the token as a plain hex `var()` silently breaks every `/opacity` modifier in the system (`bg-primary/15`, `border-primary/40`, `bg-warning/10` — all of which this design system uses heavily for status pills and elevated states).

### Reusable-surface theme contract (`--su-*`)

The chat + trace-inspector surface ships as an **app-independent package** (`frontend/src/stream-ui/`, [stream-ui-ports.md](../../specs/001-contextengine-mvp/contracts/stream-ui-ports.md)). It never reads the `--color-*` tokens above — it reads its own `--su-*` contract, so it can be dropped into a client app with a completely different palette, corner radius, density, and typeface.

The binding between the two lives in **one place** (`frontend/src/theme.css`), and that mapping layer is the only file that knows both vocabularies:

```css
:root{
  --su-accent-rgb:  var(--color-primary-rgb);   /* colour: ours → the contract */
  --su-surface-rgb: var(--color-surface-rgb);
  --su-radius-card: 12px;  --su-radius-control: 8px;  --su-radius-pill: 9999px;
  --su-space: 4px;  --su-row-gap: 2px;  --su-indent: 16px;
  --su-font-sans: "Fira Sans";  --su-font-mono: "Fira Code";
}
```

| Group | Tokens |
|---|---|
| Colour | `--su-canvas-rgb` · `--su-surface-rgb` · `--su-surface-2-rgb` · `--su-border-rgb` · `--su-text-rgb` · `--su-text-muted-rgb` · `--su-accent-rgb` · `--su-info-rgb` · `--su-warn-rgb` · `--su-danger-rgb` |
| Shape | `--su-radius-card` · `--su-radius-control` · `--su-radius-pill` · `--su-border-width` |
| Density | `--su-space` · `--su-row-gap` · `--su-indent` |
| Type | `--su-font-sans` · `--su-font-mono` · `--su-text-size` · `--su-text-size-mono` |

Inside that surface, **use `rounded-card` / `rounded-control` / `rounded-pill`, never `rounded-lg`/`rounded-md`/`rounded-full`** — a literal radius utility is a hard-coded shape decision a client app cannot override, and it is as much a coupling as a hard-coded colour. Enforced by the T100a static scan.

### Typography

- **Heading Font:** Fira Code
- **Body Font:** Fira Sans
- **Mood:** dashboard, data, analytics, code, technical, precise
- **Google Fonts:** [Fira Code + Fira Sans](https://fonts.google.com/share?selection.family=Fira+Code:wght@400;500;600;700|Fira+Sans:wght@300;400;500;600;700)

**CSS Import:**
```css
@import url('https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600;700&family=Fira+Sans:wght@300;400;500;600;700&display=swap');
```

### Spacing Variables

| Token | Value | Usage |
|-------|-------|-------|
| `--space-xs` | `4px` / `0.25rem` | Tight gaps |
| `--space-sm` | `8px` / `0.5rem` | Icon gaps, inline spacing |
| `--space-md` | `16px` / `1rem` | Standard padding |
| `--space-lg` | `24px` / `1.5rem` | Section padding |
| `--space-xl` | `32px` / `2rem` | Large gaps |
| `--space-2xl` | `48px` / `3rem` | Section margins |
| `--space-3xl` | `64px` / `4rem` | Hero padding |

### Shadow Depths

| Level | Value | Usage |
|-------|-------|-------|
| `--shadow-sm` | `0 1px 2px rgba(0,0,0,0.05)` | Subtle lift |
| `--shadow-md` | `0 4px 6px rgba(0,0,0,0.1)` | Cards, buttons |
| `--shadow-lg` | `0 10px 15px rgba(0,0,0,0.1)` | Modals, dropdowns |
| `--shadow-xl` | `0 20px 25px rgba(0,0,0,0.15)` | Hero images, featured cards |

---

## Component Specs

### Buttons

```css
/* Primary Button — run green */
.btn-primary {
  background: #22C55E;
  color: #04210F;
  padding: 10px 20px;
  border-radius: 8px;
  font-weight: 600;
  transition: all 200ms ease;
  cursor: pointer;
}

.btn-primary:hover {
  background: #16A34A;
}

/* Secondary Button — outlined on dark */
.btn-secondary {
  background: transparent;
  color: #F8FAFC;
  border: 1px solid #334155;
  padding: 10px 20px;
  border-radius: 8px;
  font-weight: 500;
  transition: all 200ms ease;
  cursor: pointer;
}

.btn-secondary:hover {
  background: #1E293B;
  border-color: #475569;
}
```

### Cards

```css
.card {
  background: #1E293B;
  border: 1px solid #334155;
  border-radius: 12px;
  padding: 24px;
  box-shadow: var(--shadow-md);
  transition: all 200ms ease;
}

/* Only interactive cards get a hover lift + pointer */
.card--interactive {
  cursor: pointer;
}
.card--interactive:hover {
  border-color: #475569;
  box-shadow: var(--shadow-lg);
}
```

### Inputs

```css
.input {
  background: #0F172A;
  color: #F8FAFC;
  padding: 10px 14px;
  border: 1px solid #334155;
  border-radius: 8px;
  font-size: 14px;
  transition: border-color 200ms ease, box-shadow 200ms ease;
}

.input::placeholder { color: #64748B; }

.input:focus {
  border-color: #22C55E;
  outline: none;
  box-shadow: 0 0 0 3px rgba(34,197,94,0.20);
}
```

### Modals

```css
.modal-overlay {
  background: rgba(2, 6, 23, 0.7);
  backdrop-filter: blur(4px);
}

.modal {
  background: #1E293B;
  border: 1px solid #334155;
  border-radius: 16px;
  padding: 28px;
  box-shadow: var(--shadow-xl);
  max-width: 520px;
  width: 90%;
  color: #F8FAFC;
}
```

---

## Style Guidelines

**Style:** Technical Dark Console — precise, data-dense, observability-forward

**Keywords:** dark-first, slate surfaces, monospace accents, high-signal density, status-driven color, calm motion, developer-trust

**Best For:** Developer tools, AI/observability dashboards, admin consoles, data-heavy SaaS

**Key Effects:** subtle 1px borders to separate surfaces (not heavy shadows), monospace (Fira Code) for IDs/scores/tokens/credits, status pills, skeleton loaders, token-by-token streaming for AI text, calm 150–250ms transitions, NO scale transforms that shift layout.

### App Shell Pattern

**Pattern Name:** Persistent Sidebar + Top Bar Dashboard

- **Layout:** Fixed left sidebar (org + workspace switcher, then primary nav), sticky top bar (search, credit meter, notification bell, user menu), scrollable content region. Optional right-hand inspector/debug drawer that slides in.
- **Navigation:** Sidebar items — Library, Chat, Workspace, Credits, Admin, Agents, Notifications. Active item marked with run-green left accent bar. The Notifications item carries an unread-count badge and mirrors the top-bar bell's count. The **Organization** screen (`pages/organization.md`) is intentionally *not* a nav item — it opens from the switcher and is hidden entirely for single-workspace customers.
- **Shared shell:** the sidebar **and the top-bar chrome** (credit meters, notification bell, user menu) are generated for every mockup by `.stitch/build.py`; edit them there, not per file (`--check` fails on drift). The chrome is generated rather than hand-copied because hand-copying had already failed — the "always-visible credit meter" below was specified in this file and present on two of eight screens. The demo balance figures also live in that one script, so no two screens can disagree about the same workspace's usage (they did: 82% on Credits and Admin, 67% on Organization).
- **Density:** Information-dense but grouped into cards/panels with clear headers; use the spacing scale, not large landing-page gaps.
- **Global chrome:** Credit balance meter is always visible in the top bar; near-limit (≥80%) turns amber, exhausted turns red. A **notification bell** sits beside the user menu: it shows an unread-count badge and opens a dropdown inbox; the unread count and new items update live over the existing stream (SSE) without a page reload. Full history + per-category delivery preferences live on the dedicated Notifications screen (`pages/notifications.md`).

### Reusable patterns

- **Status pill:** rounded-full, 12px Fira Code, semantic bg at ~15% opacity + solid text (e.g. `processing` = cyan, `ready` = green, `failed` = red, `queued` = muted).
- **Clearance badge:** lock badge rendered from the workspace `clearance_scheme` (2–5 levels, default 5); higher levels use warmer/stronger accent. Never hardcode a level name — a customer running a 3-tier scheme must never see a label they did not configure. Never show documents above the viewer's clearance.
- **Group chip** *(Phase 2):* second access axis. Native groups use an info-tinted pill; mirrored groups use a neutral outline plus a source badge (`confluence`, `git`) and are read-only. Rendered as a flat set, never as ladder rungs — groups are unordered, and rank never grants one.
- **Rating control** *(Phase 2):* thumbs up/down pair in an answer footer; selected up = run-green, selected down = red, re-click clears. Dislike reveals an optional ≤500-char reason. Never show counts or other members' ratings.
- **Phase chip:** muted pill reading `Phase 2` / `Phase 4`, marking future-phase affordances staged in the mockups so reviewers can separate shipped surface from design intent.
- **Citation chip:** inline numbered `[1]` chip in run-green that links to the source document/section.
- **Metric/score:** numeric values, scores, token counts, and credit amounts always set in Fira Code.
- **Meter (`.meter` / `.meter-fill`):** the one bar used for every credit balance, allocation and share-of-total, generated into every page by `.stitch/build.py`. Two rules make it trustworthy rather than decorative: **the fill always encodes the amount *consumed*, never the amount remaining** (a bar next to a "12,480 left" headline is otherwise read backwards), and it is a real `role="progressbar"` with `aria-valuenow` + an `aria-valuetext` that spells out the ratio. The painted width and the ARIA value both derive from a single `--meter-pct`, so they cannot drift apart. Tone comes from the state rule below, never from the categorical ramp.
- **Notification bell + badge:** outline bell in the top bar; unread count shown as a small run-green pill (red when any item is `urgent` priority). Empty/zero state hides the badge entirely. Badge count is Fira Code.
- **Notification item:** a left category icon, a title (Fira Sans 14, semibold) + one-line body, a relative timestamp (muted), and an unread dot (run-green) on the left edge. The whole row is clickable and deep-links to the originating resource. Unread rows use a faint elevated surface (`--color-surface-2`); read rows drop to the base surface.
- **Notification category icon/accent:** each category maps to a consistent icon + semantic accent — `ingestion` (cyan), `invite/member` (run-green), `credit` (amber → red when exhausted), `agent/task-halted` (amber), `approval_requested` (a **shield/gavel** icon, run-green — actionable; the item deep-links to the pending approval and, when it is a paused agent run, into its detail), `share/clearance` (info cyan), `broadcast` (run-green megaphone). Use the same SVG icon set as the rest of the app (no emojis).
- **Approval card (human-in-the-loop gate):** the inline control that surfaces whenever an action pauses for a human decision (FR-040) — a note-enrich draft accept, an agent **web_search** before a fetch, an agent **note-edit** diff, a model-suggested clearance bump, or a paused long-horizon step. Elevated surface (`--color-surface-2`), a title stating *what* is being approved, a body/diff preview (for `note_edit`, a red/green line diff of the proposed `body`; for `web_search`, the intended query + target host), the acting agent's identity + effective clearance where relevant, and a three-action footer: **Approve** (run-green primary), **Reject** (secondary/danger), and — where the value is editable — **Edit & approve** (opens the value for correction first). While pending it shows a muted "awaiting your approval — nothing runs or is charged yet" line; on resolve it collapses to a `resumed`/`rejected` status. Never auto-approve on timeout; an expired gate reads as rejected.
- **`paused` / awaiting-approval status pill:** a distinct amber pill (`awaiting approval`) for a long-horizon run or action stopped at a human gate — visually separate from `running` (green) and `halted-cost-cap` (red). It carries a small badge count when more than one gate is pending and is the entry point to the approval card.
- **Toast (transient):** for high-priority live events a small toast may slide in top-right (`--color-surface-2`, 1px border, auto-dismiss ~5s, pauses on hover, respects `prefers-reduced-motion`). Toasts never replace the persisted inbox entry.

---

## Anti-Patterns (Do NOT Use)

- ❌ Light mode / white backgrounds (this is a dark-first product in Phase 1)
- ❌ Heavy drop-shadows to separate panels (prefer 1px slate borders)
- ❌ Showing any document, citation, or score above the viewer's clearance level
- ❌ Marketing/landing tropes (hero journeys, oversized type, scroll-snap)

### Additional Forbidden Patterns

- ❌ **Emojis as icons** — Use SVG icons (Heroicons, Lucide, Simple Icons)
- ❌ **Missing cursor:pointer** — All clickable elements must have cursor:pointer
- ❌ **Layout-shifting hovers** — Avoid scale transforms that shift layout
- ❌ **Low contrast text** — Maintain 4.5:1 minimum contrast ratio
- ❌ **Instant state changes** — Always use transitions (150-300ms)
- ❌ **Invisible focus states** — Focus states must be visible for a11y

---

## Pre-Delivery Checklist

Before delivering any UI code, verify:

- [ ] No emojis used as icons (use SVG instead)
- [ ] All icons from consistent icon set (Heroicons/Lucide)
- [ ] `cursor-pointer` on all clickable elements
- [ ] Hover states with smooth transitions (150-300ms)
- [ ] Text contrast ≥ 4.5:1 **against the surface it actually sits on** — `--color-surface-2` is the strictest of the three and is where captions fail first. Only the three text tokens are legal for body text; a raw `slate-*` utility is the failure mode this rule exists to catch (the previous wording said "Light mode: …", which is unreachable advice in a dark-only product and let every dark-surface failure through)
- [ ] Focus states visible for keyboard navigation — Tailwind's reset removes the UA outline, so the ring in the generated `#shell-style` block is what provides it; don't suppress it per page
- [ ] `prefers-reduced-motion` respected (also in `#shell-style`)
- [ ] Meters carry `role="progressbar"` + `aria-valuenow`/`aria-valuetext`, and the fill encodes *consumed*, not remaining
- [ ] Chart series use `--color-chart-1…4` in fixed order; no status colour used as a series, no series colour used as a state
- [ ] Responsive: 375px, 768px, 1024px, 1440px
- [ ] No content hidden behind fixed navbars
- [ ] No horizontal scroll on mobile
