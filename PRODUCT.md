# Product

## Register

product

## Users

Privacy-conscious individuals managing their own work and personal tasks — one user, often across several devices (iPhone and iPad as co-equal first-class targets, plus the existing GSD web app). Their context is the middle of a busy day: a task occurs to them and they want it captured and classified before the thought is gone, without breaking stride.

The job to be done is **decide what matters, then act**. GSD frames every task on two axes — urgent and important — and sorts it into one of four quadrants (do first, schedule, delegate, eliminate). The user opens the app to answer "what do I work on next?" and to keep that answer honest as things change. They can do all of this with no account and no network; signing in is an optional convenience for keeping devices and the web app in step.

## Product Purpose

GSD ("Get Stuff Done") is a **privacy-first, offline-first Eisenhower-matrix task manager** — a native SwiftUI rebuild and reimagining of the GSD web app for iPhone and iPad.

All data lives on-device and the app is fully usable with no account and no network. Cloud sync (bidirectional with the existing PocketBase backend and the web app) is strictly **optional and opt-in**. Behind the simple 2×2 grid sits the full feature set: natural-language capture parser, recurrence, subtasks, dependency graphs, time tracking, snooze, archive, smart views, search and command palette, an analytics dashboard, import/export, and local notifications — plus native surfaces a web view can't deliver: Home/Lock-Screen widgets, App Intents/Siri/Shortcuts, a Share Extension, and Spotlight.

Success looks like: a user can capture, classify, edit, complete, and organize tasks entirely offline in a UI that feels **designed for iOS, not ported**; signing in syncs deterministically across devices and the web; and the app passes App Store review with accurate privacy labels.

## Brand Personality

**Editorial · Calm · Focused.**

- **Editorial** — magazine-like restraint. A serif display typeface (Apple "New York") for headings, generous spacing, deliberate hierarchy. The interface reads as composed, not assembled.
- **Calm** — restrained color is the whole strategy. The four quadrant accents carry the only strong color in the app; everything else is neutral. Nothing competes for attention that doesn't need it.
- **Focused** — one clear surface, one decision at a time. The product helps the user choose what to do next and get out of the way.

Voice and tone: quiet, unhurried, trustworthy. The emotional goal is **calm clarity and confidence** — the opposite of urgency-bait. GSD never manufactures pressure to keep someone in the app.

## Anti-references

What GSD must **not** look or feel like:

- **Dense corporate-SaaS** (Jira / Asana / Monday): crowded toolbars, data-dense tables, enterprise chrome. GSD favors a single quiet surface over a control panel.
- **Neon / glassy / gradient-heavy**: glassmorphism, dark-neon "productivity" aesthetics, decorative gradients. These fight the editorial calm; color stays rationed and purposeful.
- **Playful / cartoonish**: bright illustration-heavy layouts, mascots, toy-like rounding. GSD is a serious adult tool, not a cute app.
- **Gamified / streak-driven** (Habitica / Todoist-karma): streaks, badges, points, dopamine loops. GSD measures progress honestly (the dashboard) without manufacturing reward to drive engagement.

## Design Principles

1. **Privacy is the product, not a setting.** Offline-first and on-device by default; sync is opt-in. The UI must never imply data leaves the device when it doesn't — copy and affordances tell the truth about where data lives.
2. **Depth under a calm surface.** The 2×2 grid stays simple. Recurrence, dependencies, time tracking, analytics, and sync live one layer down — reachable, never crowding the primary "what next?" decision.
3. **Native, not ported.** Reimagine around iOS idioms — swipe actions, context menus, drag-and-drop, widgets, App Intents, `NavigationSplitView` — rather than transliterating web layouts. iPhone and iPad are co-equal, each laid out for its size class.
4. **Frictionless capture.** Adding and classifying a task is one keystroke-light gesture; the capture field is always one tap away, and natural-language shorthand (`!`, `!!`, `*`, `#tag`) does the classifying.
5. **Restraint carries the brand.** Color is rationed to the quadrant accents; typography does the hierarchy work (serif display + system body); motion is intentional and always Reduce-Motion-aware. When in doubt, remove rather than add.

## Accessibility & Inclusion

Target **WCAG AAA where feasible, with AA as the firm floor.**

- **Contrast:** quadrant accent colors meet at least AA against their card backgrounds in both light and dark; push body text toward AAA where it doesn't break the rationed palette. (The quadrant accents in `App/Theme/QuadrantStyle.swift` carry a standing note to re-verify these pairs.)
- **VoiceOver:** every interactive element labeled; the matrix, cards, and editor are navigable and announce state (completed, blocked, overdue).
- **Dynamic Type:** layouts hold up to the accessibility (AX) sizes; headings use Dynamic-Type-aware text styles, never fixed point sizes.
- **Reduce Motion:** confetti and non-essential animation are suppressed when Reduce Motion is on (mirrors the web's `prefers-reduced-motion` behavior).
- **Localization-ready:** `String(localized:)` throughout, no concatenated UI strings, so the architecture never hard-blocks future languages (English at launch).

> A manual accessibility validation pass (VoiceOver + Dynamic Type at AX sizes + Reduce Motion across all surfaces) is still owed before App Store submission — it needs a real device and a human, and is tracked in the project state.
