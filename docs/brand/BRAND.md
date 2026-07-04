# PatchManager Brand

PatchManager is evidence-led Windows patching: keep endpoints current and prove
the result with audit-ready reports.

## Core Idea

- Category: Windows patching, compliance, fleet reporting, endpoint trust.
- Audience: IT admins, MSPs, and security-conscious power users.
- Promise: patch, verify, and prove current state in one auditable run.
- Metaphor: protected evidence ledger.
- Mark: shield boundary, document surface, and verified path.

## Assets

- `patchmanager-mark.svg` is the compact mark for icons, report navigation,
  social previews, and small lockups.
- `patchmanager-wordmark.svg` is the preferred public README/header lockup.
- `patchmanager-brand-board.svg` is the lightweight brand overview board.

## Palette

| Token | Hex | Use |
|---|---:|---|
| Charcoal Ink | `#111513` | Primary text, dark panels, mark core |
| Ivory Paper | `#F6F2E8` | Report surfaces and brand backgrounds |
| Audit Blue | `#18324A` | Trust, document outlines, UI structure |
| Verified Green | `#24744F` | Success, verified update state |
| Caution Amber | `#C49A3D` | Stale, waiting, review cues |
| Exposure Red | `#A53B35` | Failures, KEV, SLA pressure |

## Typography

Use the existing Windows-safe stack:

```css
"Segoe UI Variable Display", "Aptos Display", "Segoe UI", system-ui, sans-serif
```

Use `Cascadia Mono` or `Consolas` only for commands, versions, and machine
evidence.

## Voice

Use calm, specific language. Prefer evidence terms: verified, current, stale,
blocked, failed, applied, pending, source, report, proof. Avoid hype and vague
security theatre.

## User Prompts

Native prompts should use the same trust language as reports: a charcoal header,
ivory surface, audit-blue boundary, verified-green primary action, and concise
evidence-led copy. Use the PatchManager mark in prompt headers where the UI
framework allows it. For native controls that cannot embed SVG directly, recreate
the same shield/document/check geometry and palette rather than inventing a new
symbol.

## Rules

- Keep reports self-contained: no remote fonts, images, CDN scripts, or runtime
  dependencies.
- Use the SVG mark consistently; do not redraw alternate shield/check marks.
- Keep spacing generous and interface density readable.
- Do not use the mark as decoration where it does not reinforce trust or
  provenance.
