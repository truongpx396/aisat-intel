# Design System Master File

> **LOGIC:** When building a specific page, first check `design-system/pages/[page-name].md`.
> If that file exists, its rules **override** this Master file.
> If not, strictly follow the rules below.

---

**Project:** AISAT-STUDIO
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
| Accent / CTA (run green) | `#22C55E` | `--color-cta` |
| Info (cyan) | `#38BDF8` | `--color-info` |
| Warning (amber) | `#FBBF24` | `--color-warning` |
| Danger (red) | `#EF4444` | `--color-danger` |

**Color Notes:** "Code dark + run green" — a slate-900 canvas with slate-800 elevated surfaces, run-green for primary/success actions, and a small semantic accent set (cyan/amber/red) reserved for status, scores, and credit states. This is a dark-first developer/observability product; there is no light mode in Phase 1.

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

- **Layout:** Fixed left sidebar (workspace switcher + primary nav), sticky top bar (search, credit meter, user menu), scrollable content region. Optional right-hand inspector/debug drawer that slides in.
- **Navigation:** Sidebar items — Library, Chat, Workspace, Credits, Admin, Agents. Active item marked with run-green left accent bar.
- **Density:** Information-dense but grouped into cards/panels with clear headers; use the spacing scale, not large landing-page gaps.
- **Global chrome:** Credit balance meter is always visible in the top bar; near-limit (≥80%) turns amber, exhausted turns red.

### Reusable patterns

- **Status pill:** rounded-full, 12px Fira Code, semantic bg at ~15% opacity + solid text (e.g. `processing` = cyan, `ready` = green, `failed` = red, `queued` = muted).
- **Clearance badge:** L1–L5 lock badge; higher levels use warmer/stronger accent. Never show documents above the viewer's clearance.
- **Citation chip:** inline numbered `[1]` chip in run-green that links to the source document/section.
- **Metric/score:** numeric values, scores, token counts, and credit amounts always set in Fira Code.

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
- [ ] Light mode: text contrast 4.5:1 minimum
- [ ] Focus states visible for keyboard navigation
- [ ] `prefers-reduced-motion` respected
- [ ] Responsive: 375px, 768px, 1024px, 1440px
- [ ] No content hidden behind fixed navbars
- [ ] No horizontal scroll on mobile
