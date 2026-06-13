---
name: AISAT-STUDIO Dark Console
colors:
  background: '#0F172A'
  on-background: '#F8FAFC'
  surface: '#1E293B'
  surface-dim: '#0F172A'
  surface-bright: '#273449'
  surface-container-lowest: '#0F172A'
  surface-container-low: '#1A2435'
  surface-container: '#1E293B'
  surface-container-high: '#273449'
  surface-container-highest: '#334155'
  on-surface: '#F8FAFC'
  on-surface-variant: '#94A3B8'
  inverse-surface: '#F8FAFC'
  inverse-on-surface: '#0F172A'
  outline: '#334155'
  outline-variant: '#475569'
  surface-tint: '#22C55E'
  primary: '#22C55E'
  on-primary: '#04210F'
  primary-container: '#14361F'
  on-primary-container: '#86EFAC'
  inverse-primary: '#16A34A'
  secondary: '#334155'
  on-secondary: '#F8FAFC'
  secondary-container: '#273449'
  on-secondary-container: '#CBD5E1'
  tertiary: '#38BDF8'
  on-tertiary: '#04212E'
  tertiary-container: '#0C3A52'
  on-tertiary-container: '#BAE6FD'
  error: '#EF4444'
  on-error: '#2A0707'
  error-container: '#4C1313'
  on-error-container: '#FCA5A5'
  warning: '#FBBF24'
  on-warning: '#2A1D03'
  background-variant: '#1E293B'
  surface-variant: '#273449'
typography:
  display-lg:
    fontFamily: Fira Code
    fontSize: 36px
    fontWeight: '600'
    lineHeight: 44px
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Fira Code
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: '0'
  title-sm:
    fontFamily: Fira Sans
    fontSize: 16px
    fontWeight: '600'
    lineHeight: 22px
    letterSpacing: '0'
  body-base:
    fontFamily: Fira Sans
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 22px
    letterSpacing: '0'
  body-bold:
    fontFamily: Fira Sans
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 22px
    letterSpacing: '0'
  label-caps:
    fontFamily: Fira Sans
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.06em
  mono-data:
    fontFamily: Fira Code
    fontSize: 13px
    fontWeight: '500'
    lineHeight: 18px
    letterSpacing: '0'
rounded:
  sm: 0.375rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  gutter: 16px
  margin-mobile: 20px
  margin-desktop: 40px
---

## Brand & Style

AISAT-STUDIO is an AI-powered shared second brain for work teams — a developer-
and operator-facing product where every architectural pattern (retrieval tiers,
access filtering, credit metering, provider fallback) must be *observable and
named*. The personality is **technical, precise, and trustworthy**: a dark "code
console" canvas with run-green accents that signal active/successful AI work.

- **Mood:** dark-first, data-dense, calm. Slate-900 canvas, slate-800 elevated
  surfaces separated by 1px slate borders rather than heavy shadows.
- **Accent system:** run-green (`primary`) for primary actions and success/ready
  states; cyan (`tertiary`) for informational/score states; amber (`warning`)
  for near-limit and fallback states; red (`error`) for blocked/refused/failed.
- **Numerics are monospace:** all IDs, scores, token counts, credit amounts, and
  trace fingerprints use Fira Code (`mono-data`). Prose and UI labels use Fira Sans.

## Layout System

Persistent left **sidebar** (workspace switcher + primary nav: Library, Chat,
Workspace, Credits, Admin, Agents) + sticky **top bar** (search, always-visible
credit meter, user menu) + scrollable content. The **Chat** screen adds a right
**debug/inspector drawer** that exposes per-answer reasoning.

## Components

- **Status pill:** `full` radius, `label-caps`, semantic color at ~15% opacity
  fill with solid text — `queued` (muted), `processing/embedding` (cyan),
  `captioning` (amber), `ready` (green), `failed` (red).
- **Clearance badge:** L1–L5 lock badge in `tertiary` tint; never render content
  above the viewer's clearance.
- **Citation chip:** inline numbered `[n]` chip in `primary`, links to the source.
- **Card:** `surface` fill, 1px `outline` border, `md` radius; interactive cards
  add a hover border-lighten (no layout-shifting scale).
- **Credit meter:** horizontal bar — green → amber at ≥80% → red when exhausted.
- **Buttons:** primary = run-green fill with near-black text; secondary = outline
  on dark.

## Accessibility & Motion

- Maintain 4.5:1 contrast on the dark canvas; visible keyboard focus rings in
  `primary` at 20% alpha.
- Transitions 150–250ms; respect `prefers-reduced-motion`. AI answers stream
  token-by-token instead of long spinners.
- SVG icons only (Heroicons/Lucide), never emoji.

## Anti-Patterns

- No light mode / white surfaces (Phase 1 is dark-first).
- No heavy drop-shadows to separate panels (use 1px borders).
- Never surface a document, citation, or score above the viewer's clearance.
- No marketing/landing tropes (hero journeys, oversized type, scroll-snap).
