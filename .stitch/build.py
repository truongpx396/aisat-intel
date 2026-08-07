#!/usr/bin/env python3
"""Regenerate the shared app shell (sidebar + top-bar chrome) across every mockup.

The sidebar — logo, org/workspace switcher and primary nav — is identical on every
screen, so editing it by hand meant an N-file synchronized change every time (and a
missed file meant a silently inconsistent mockup). It lives here once instead.

The **top-bar chrome** (credit meter, notification bell, user menu) is owned here for
the same reason, and because hand-copying it had already failed: MASTER.md and
DESIGN.md both specify an always-visible credit meter, and it existed on two of eight
screens. A rule that lives only in prose is a rule that drifts, so the meter is now
generated onto every screen from one definition — including the balance/threshold
numbers, which previously disagreed between pages.

Usage:  python3 .stitch/build.py [--check]
        --check exits non-zero if any file is out of date, for CI.

Everything else about a page — head, per-page CSS, header title/tabs, content — stays
in its own file. This script owns exactly two regions per page:
    <aside …> … </aside>
    <!-- @shell:chrome --> … <!-- /@shell:chrome -->   (inside <header>)
"""
import re, sys, pathlib

DESIGNS = pathlib.Path(__file__).parent / "designs"

ICON = {
 "library": '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>',
 "chat": '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22z"/>',
 "workspace": '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
 "credits": '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/>',
 "admin": '<path d="M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16z"/><path d="M12 8v4l3 2"/>',
 "agents": '<rect x="3" y="11" width="18" height="10" rx="2"/><circle cx="12" cy="5" r="2"/><path d="M12 7v4"/>',
 "notifications": '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
}
NAV = [
 ("library", "Library", "library.html"),
 ("chat", "Chat", "chat.html"),
 ("workspace", "Workspace", "workspace.html"),
 ("credits", "Credits", "credits.html"),
 ("admin", "Admin", "admin.html"),
 ("agents", "Agents", "agents.html"),
 ("notifications", "Notifications", "notifications.html"),
]
UNREAD = 3

# The demo tenant's credit position, in ONE place. Every screen that shows a balance —
# top-bar meter, the notification item, the Credits hero, the org allocation table —
# renders from these numbers. They used to be typed per file and had already diverged
# (Credits and Admin agreed on 82% while Organization showed the same workspace at
# 67%), which is a bad look on a product whose pitch is exact reconciliation.
BALANCE = {
    "ws_left": "12,480", "ws_total": "70,000", "ws_pct": 82,
    "daily_left": "410", "daily_total": "1,000", "daily_pct": 59,
}
# Amber at >= 80%, red at exhaustion (MASTER.md "Global chrome"). Encoded here so the
# threshold is applied rather than remembered.
WARN_AT = 80


def meter_tone(pct):
    return "danger" if pct >= 100 else "warning" if pct >= WARN_AT else "primary"

# Conversation list (FR-009). APP CHROME — deliberately not part of the reusable
# stream-ui/ package: history is a host persistence concern, and the package renders
# A run, not the history of runs. Ordering is by last_message_at, never created_at.
CHAT_EXTRA = '''      <!-- Conversation list — FR-009 -->
      <div class="flex min-h-0 flex-1 flex-col border-t border-line">
        <div class="px-3 pt-3">
          <button class="flex w-full items-center gap-2 rounded-control border border-line bg-canvas px-2.5 py-1.5 text-sm text-ink hover:border-primary hover:bg-primary/5 transition">
            <svg class="h-3.5 w-3.5 text-primary" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14"/><path d="M5 12h14"/></svg>
            New chat
          </button>
        </div>

        <div class="mt-3 min-h-0 flex-1 overflow-y-auto px-3 pb-3">
          <!-- Grouped by last_message_at — a chat replied to an hour ago outranks one
               opened last week and abandoned. Ordering by created_at is the bug this prevents. -->
          <p class="px-2 pb-1 text-[10px] uppercase tracking-wider text-muted">Today</p>
          <div class="group flex items-center gap-1 rounded-control bg-surface2 pr-1">
            <a href="#" class="block flex-1 truncate px-2 py-1.5 text-sm text-primary" title="Q3 revenue drivers">Q3 revenue drivers</a>
            <!-- row actions: rename · archive · delete. Archive and delete are DIFFERENT
                 actions and are never merged into one control. -->
            <span class="flex shrink-0 items-center gap-0.5 opacity-0 group-hover:opacity-100 transition">
              <button class="grid h-5 w-5 place-items-center rounded-control text-muted hover:text-ink" title="Rename">
                <svg class="h-3 w-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>
              </button>
              <button class="grid h-5 w-5 place-items-center rounded-control text-muted hover:text-ink" title="Archive — hides this chat, keeps its memory">
                <svg class="h-3 w-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8"/><path d="M10 12h4"/></svg>
              </button>
              <button class="grid h-5 w-5 place-items-center rounded-control text-muted hover:text-danger" title="Delete — destroys this chat AND purges its memories">
                <svg class="h-3 w-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18"/><path d="M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2"/><path d="M19 6l-1 14a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1L5 6"/></svg>
              </button>
            </span>
          </div>

          <p class="px-2 pb-1 pt-3 text-[10px] uppercase tracking-wider text-muted">Previous 7 days</p>
          <a href="#" class="block truncate rounded-control px-2 py-1.5 text-sm text-muted hover:bg-surface2 hover:text-ink" title="Onboarding policy summary">Onboarding policy summary</a>
          <!-- deleting: shown in-flight, NOT optimistically removed — the Mem0 purge must
               confirm before the row goes, and a failed purge retries rather than silently
               resurrecting the chat later. -->
          <div class="flex items-center gap-2 rounded-control px-2 py-1.5 opacity-60">
            <svg class="h-3 w-3 shrink-0 animate-spin text-muted" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12a9 9 0 1 1-6.2-8.6"/></svg>
            <span class="min-w-0 flex-1 truncate text-sm text-muted line-through">Security model overview</span>
          </div>
          <p class="px-2 pb-1 font-mono text-[10px] text-muted">deleting · purging memory</p>

          <button class="mt-2 w-full rounded-control px-2 py-1 text-left font-mono text-[11px] text-muted hover:text-ink">load more ↓</button>
        </div>
      </div>
'''

# active = which nav item is current; None = an org-scoped screen, where the switcher
# is highlighted instead (Organization is reached from the switcher, not from nav).
PAGES = {
 "library.html": {"active": "library"},
 "chat.html": {"active": "chat", "extra": CHAT_EXTRA},
 "workspace.html": {"active": "workspace"},
 "credits.html": {"active": "credits"},
 "admin.html": {"active": "admin"},
 "agents.html": {"active": "agents"},
 "notifications.html": {"active": "notifications"},
 "organization.html": {"active": None},
}

def nav_item(key, label, href, active):
    badge = ('\n          <span class="ml-auto grid h-4 min-w-4 place-items-center rounded-full '
             f'bg-primary px-1 font-mono text-[10px] font-bold text-[#04210F]">{UNREAD}</span>'
             ) if key == "notifications" else ""
    if key == active:
        return (f'        <a class="relative flex items-center gap-3 rounded-lg bg-surface2 px-3 py-2 font-medium text-ink" href="#">\n'
                f'          <span class="absolute left-0 top-1.5 bottom-1.5 w-0.5 rounded-full bg-primary"></span>\n'
                f'          <svg class="h-4 w-4 text-primary" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">{ICON[key]}</svg> {label}{badge}</a>')
    return (f'        <a class="flex items-center gap-3 rounded-lg px-3 py-2 text-muted hover:bg-surface2 hover:text-ink transition" href="{href}">\n'
            f'          <svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">{ICON[key]}</svg> {label}{badge}</a>')

def sidebar(active, extra=""):
    # org-scoped screens highlight the switcher, since they have no nav item
    border = "border-primary/40" if active is None else "border-line"
    hover = "hover:border-primary" if active is None else "hover:border-slate-500"
    items = "\n".join(nav_item(k, l, h, active) for k, l, h in NAV)
    return f'''    <aside class="hidden md:flex w-60 shrink-0 flex-col border-r border-line bg-surface sidebar-texture">
      <div class="flex items-center gap-2 px-5 h-16 border-b border-line">
        <span class="grid place-items-center h-8 w-8 rounded-lg bg-primary text-[#04210F] font-mono font-bold">A</span>
        <span class="font-mono font-semibold tracking-tight text-gradient">AISAT<span style="-webkit-text-fill-color:#22C55E">·</span>INTEL</span>
      </div>
      <!-- Org + workspace switcher. The org line renders only when the org has more than
           one workspace or an enterprise plan; Organization settings open from here, which
           is why there is no Organization nav item. -->
      <button class="mx-3 mt-3 flex items-center justify-between rounded-lg border {border} bg-canvas px-3 py-2 text-sm {hover} transition">
        <span class="flex min-w-0 flex-col items-start gap-0.5">
          <span class="flex items-center gap-1 truncate text-[10px] uppercase tracking-wider text-muted">
            <svg class="h-2.5 w-2.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 21h18"/><path d="M5 21V7l7-4 7 4v14"/></svg>
            Acme Corp
          </span>
          <span class="flex items-center gap-2 text-sm"><span class="h-5 w-5 grid place-items-center rounded bg-info/20 text-info text-xs font-mono">Q3</span> Acme · Research</span>
        </span>
        <svg class="h-4 w-4 text-muted" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m6 9 6 6 6-6"/></svg>
      </button>
      <nav class="mt-4 flex-1 space-y-1 px-3 text-sm">
{items}
      </nav>
{extra}    </aside>'''

def credit_meter(label, left, total, pct, tone, icon, title):
    """One top-bar meter. role=progressbar because a bare tinted <span> tells assistive
    tech nothing about the number it is drawing — and this is the number that decides
    whether the user's next action works."""
    return f'''          <div class="flex items-center gap-2 rounded-lg border border-line bg-surface px-3 py-1.5" title="{title}">
            <svg class="h-3.5 w-3.5 text-{tone}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">{icon}</svg>
            <span class="font-mono text-sm">{left}</span>
            <span class="text-xs text-muted">{label}</span>
            <span class="meter h-1.5 w-12" style="--meter-pct:{pct}%" role="progressbar"
                  aria-label="{title}" aria-valuenow="{pct}" aria-valuemin="0" aria-valuemax="100"
                  aria-valuetext="{pct}% of {total} used, {left} left"><span class="meter-fill bg-{tone}"></span></span>
          </div>'''


NOTIF_ITEMS = [
    ("library.html", "info",
     '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="m9 15 2 2 4-4"/>',
     'Ingestion complete — <span class="font-medium">Q3-revenue.pdf</span>', "Ready to query · 2m ago"),
    ("credits.html", "warning",
     '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
     f'Workspace credits {BALANCE["ws_pct"]}% used',
     f'{BALANCE["ws_left"]} of {BALANCE["ws_total"]} left · 1h ago'),
    ("agents.html", "warning",
     '<rect x="3" y="11" width="18" height="10" rx="2"/><circle cx="12" cy="5" r="2"/><path d="M12 7v4"/>',
     "Agent task halted at cost cap", "“Competitor scan” · 3h ago"),
]


def chrome(push):
    """Top-bar chrome: credit meters, notification bell, user menu.

    `push` adds ml-auto. It is omitted when the page's own header already has an
    ml-auto item — two auto margins split the free space between them, which would
    drag that item into the middle of the bar instead of leaving it right-aligned.
    """
    ws_tone = meter_tone(BALANCE["ws_pct"])
    daily_tone = meter_tone(BALANCE["daily_pct"])
    meters = "\n".join([
        credit_meter("ws left", BALANCE["ws_left"], BALANCE["ws_total"], BALANCE["ws_pct"], ws_tone,
                     '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
                     "Shared workspace balance — all members draw from this pool"),
        credit_meter("daily left", BALANCE["daily_left"], BALANCE["daily_total"], BALANCE["daily_pct"], daily_tone,
                     '<circle cx="12" cy="8" r="4"/><path d="M4 20a8 8 0 0 1 16 0"/>',
                     "Your personal daily allowance — resets at midnight UTC"),
    ])
    items = "\n".join(
        f'''              <a href="{href}" class="flex gap-3 bg-surface2 px-4 py-3 transition hover:bg-surface">
                <span class="mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-lg bg-{tone}/15 text-{tone}"><svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">{icon}</svg></span>
                <span class="min-w-0 flex-1"><span class="block text-sm text-ink">{title}</span><span class="block text-xs text-muted">{sub}</span></span>
                <span class="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-primary"></span>
              </a>''' for href, tone, icon, title, sub in NOTIF_ITEMS)
    cluster = "ml-auto flex items-center gap-3" if push else "flex items-center gap-3"
    return f'''        <!-- @shell:chrome -->
        <div class="{cluster}">
          <!-- Credit meters. MASTER.md requires these on EVERY screen: a balance you have
               to navigate to is a balance you discover after it blocks you. -->
          <div class="hidden sm:flex items-center gap-3">
{meters}
          </div>
          <!-- Notification bell -->
          <div class="relative" x-data="{{ notifOpen: false }}">
            <button @click="notifOpen = !notifOpen" class="relative grid h-9 w-9 place-items-center rounded-lg border border-line bg-surface text-muted transition hover:border-line hover:text-ink cursor-pointer" title="Notifications" aria-label="Notifications" :aria-expanded="notifOpen">
              <svg class="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>
              <span class="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-primary px-1 font-mono text-[10px] font-bold text-[#04210F]">{UNREAD}</span>
            </button>
            <div x-show="notifOpen" @click.outside="notifOpen = false" x-transition style="display:none" class="absolute right-0 z-50 mt-2 w-80 overflow-hidden rounded-xl border border-line bg-surface2 shadow-xl">
              <div class="flex items-center justify-between border-b border-line px-4 py-2.5">
                <span class="text-sm font-semibold">Notifications <span class="ml-1 font-mono text-xs text-muted">{UNREAD} unread</span></span>
                <button class="text-xs text-primary hover:underline cursor-pointer">Mark all read</button>
              </div>
              <div class="max-h-80 divide-y divide-line overflow-y-auto">
{items}
              </div>
              <a href="notifications.html" class="block border-t border-line px-4 py-2.5 text-center text-xs font-medium text-primary transition hover:bg-surface">View all notifications</a>
            </div>
          </div>
          <button class="grid h-9 w-9 place-items-center rounded-full bg-surface2 font-mono text-sm cursor-pointer" title="Truong P." aria-label="Account menu">TP</button>
        </div>
        <!-- /@shell:chrome -->'''


# Base rules the generated shell depends on, plus the two a11y defaults the design
# system mandates and no mockup actually had (a visible focus ring — Tailwind's reset
# removes the UA outline and nothing put one back — and reduced-motion). Emitted before
# each page's own <style>, so a page can still override.
SHELL_STYLE = '''  <style id="shell-style">
    /* Meter: the shared credit/progress bar. Driven by --meter-pct so the painted
       width and the ARIA value read from one source and cannot drift apart. */
    /* display:block, NOT inline-block — a bare `.meter` with no width utility must fill
       its container (the balance hero, the ceiling cards). Width-constrained instances
       (the top-bar meters) carry their own w-* utility. */
    .meter { overflow: hidden; border-radius: var(--su-radius-pill); background: rgb(var(--su-canvas-rgb)); display: block; }
    .meter > .meter-fill { display: block; height: 100%; width: var(--meter-pct, 0%); transition: width 200ms ease; }

    :where(a, button, [tabindex]):focus-visible {
      outline: 2px solid rgb(var(--su-accent-rgb));
      outline-offset: 2px;
      border-radius: var(--su-radius-control);
    }

    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
        scroll-behavior: auto !important;
      }
    }
  </style>'''

ASIDE = re.compile(r'    <aside class="hidden md:flex.*?</aside>', re.S)
CHROME = re.compile(r'        <!-- @shell:chrome -->.*?<!-- /@shell:chrome -->', re.S)
HEADER = re.compile(r'<header.*?</header>', re.S)
SHELL_STYLE_RE = re.compile(r'  <style id="shell-style">.*?</style>', re.S)

def main():
    check = "--check" in sys.argv
    stale = []
    for name, cfg in PAGES.items():
        path = DESIGNS / name
        if not path.exists():
            print(f"  ?? {name} missing"); stale.append(name); continue
        src = path.read_text()
        new = ASIDE.sub(lambda _: sidebar(cfg["active"], cfg.get("extra", "")), src, count=1)

        if SHELL_STYLE_RE.search(new):
            new = SHELL_STYLE_RE.sub(lambda _: SHELL_STYLE, new, count=1)
        else:  # first run: insert ahead of the page's own <style>
            new = new.replace("  <style>", SHELL_STYLE + "\n  <style>", 1)

        hm = HEADER.search(new)
        if not hm:
            print(f"  ?? {name}: no <header>"); stale.append(name); continue
        if not CHROME.search(hm.group(0)):
            print(f"  ?? {name}: no @shell:chrome region in <header>"); stale.append(name); continue
        # ml-auto only if the page's own header items don't already push right
        push = "ml-auto" not in CHROME.sub("", hm.group(0))
        header = CHROME.sub(lambda _: chrome(push), hm.group(0), count=1)
        new = new[:hm.start()] + header + new[hm.end():]

        if new == src:
            print(f"  ok {name}")
        elif check:
            print(f"  STALE {name}"); stale.append(name)
        else:
            path.write_text(new); print(f"  -> {name} updated")
    if check and stale:
        print(f"\n{len(stale)} file(s) out of date — run: python3 .stitch/build.py")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
