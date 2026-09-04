---
name: PatchManager
description: Compact evidence-led reporting for patch posture, fleet triage, and complete offline proof.
colors:
  charcoal: "#111513"
  charcoal-2: "#1a201c"
  paper: "#f7f6f1"
  paper-soft: "#f2f1eb"
  card: "#fffdf8"
  ledger-white: "#ffffff"
  ink: "#111513"
  muted: "#5f6a62"
  line: "#ddd5c2"
  line-strong: "#c8bfa6"
  blue: "#18324a"
  blue-soft: "#e8edf2"
  green: "#24744f"
  green-bg: "#e9f2ea"
  red: "#a53b35"
  red-bg: "#f7e6e1"
  amber: "#955d20"
  amber-curve: "#c49a3d"
  amber-bg: "#faf0d8"
  steel: "#365f72"
  steel-bg: "#e6eef1"
typography:
  display:
    fontFamily: '"Segoe UI Variable Display", "Aptos Display", "Segoe UI", system-ui, sans-serif'
    fontSize: "1.45rem"
    fontWeight: 800
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  heading:
    fontFamily: '"Segoe UI Variable Text", "Aptos", "Segoe UI", system-ui, -apple-system, sans-serif'
    fontSize: "1.12rem"
    fontWeight: 760
    lineHeight: 1.2
  body:
    fontFamily: '"Segoe UI Variable Text", "Aptos", "Segoe UI", system-ui, -apple-system, sans-serif'
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.42
  action:
    fontFamily: '"Segoe UI Variable Text", "Aptos", "Segoe UI", system-ui, -apple-system, sans-serif'
    fontSize: "0.76rem"
    fontWeight: 800
    lineHeight: 1.35
  label:
    fontFamily: '"Segoe UI Variable Text", "Aptos", "Segoe UI", system-ui, -apple-system, sans-serif'
    fontSize: "0.60rem"
    fontWeight: 800
    lineHeight: 1.2
    letterSpacing: "0.055em"
  status:
    fontFamily: '"Segoe UI Variable Text", "Aptos", "Segoe UI", system-ui, -apple-system, sans-serif'
    fontSize: "0.75rem"
    fontWeight: 820
    lineHeight: 1.55
  technical:
    fontFamily: '"Cascadia Mono", "Consolas", monospace'
    fontSize: "0.84rem"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  chip: "2px"
  control: "3px"
  footer: "4px"
  surface: "5px"
  circle: "50%"
spacing:
  micro: "4px"
  xs: "8px"
  sm: "10px"
  md: "12px"
  lg: "14px"
  xl: "16px"
  "2xl": "18px"
  canvas: "24px"
components:
  primary-action:
    backgroundColor: "{colors.card}"
    textColor: "{colors.blue}"
    typography: "{typography.action}"
    rounded: "{rounded.control}"
    padding: "8px 12px"
    height: "38px"
  verdict-rail:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "0"
  health-map-node:
    backgroundColor: "{colors.ledger-white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "8px 9px"
  health-map-node-selected:
    backgroundColor: "{colors.blue}"
    textColor: "#ffffff"
    rounded: "{rounded.control}"
    padding: "7px 8px"
  ledger-panel:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "12px"
  command-input:
    backgroundColor: "#ffffff"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 10px"
    height: "32px"
  status-chip:
    typography: "{typography.status}"
    rounded: "{rounded.chip}"
    padding: "2px 5px"
  ranked-exception:
    textColor: "{colors.ink}"
    padding: "11px 0"
---

# Design System: PatchManager

## Overview

**Creative North Star: "The Systems Health Map"**

PatchManager treats patch and fleet posture as a connected evidence system. Its reports expose the path from a device or estate verdict through unhealthy or risky provider domains to the exact package or host that needs action, then preserve the complete verification ledger beneath. The personality remains calm, forensic, compact, and trustworthy: this is an operational instrument, not a generic card dashboard.

The visual world is recognizable without copy: warm ivory and white evidence paper, fine charcoal rules, compact squared nodes, and restrained green, amber, red, and blue states. A light evidence header keeps identity and run provenance available without consuming the first viewport; charcoal is reserved for provenance and footer material, not the command header. Search and filters sit with the ledger they operate on, so controls and proof read as one system.

**Key Characteristics:**

- A 52–54px light evidence header precedes the verdict and work surface.
- Desktop composition brings the package or host ledger into the first viewport.
- Fine charcoal rules and tiny 2–5px radii replace floating card chrome.
- Search, filters, sorting, and result counts are colocated with their evidence ledger.
- Outlined actions inherit the current state while blue remains the navigation and neutral-action color.
- At 820px, dense tables become labeled evidence cards and controls gain a 44px interaction floor.
- Reports remain dependency-free, offline, printable, and complete without JavaScript.

## Colors

Warm paper and charcoal ink carry almost all of the interface. Blue carries interaction; green, amber, red, and steel communicate evidence state. The frontmatter is the normative palette shared by both generated report scripts.

### Primary

- **Audit Blue** (`blue`): primary actions, links, selected fleet risk nodes, and interactive emphasis.
- **Audit Blue Wash** (`blue-soft`): restrained supporting emphasis and state halos where a blue informational state is needed.

### Secondary

- **Verified Sage** (`green`): positive verification only, including zero-risk fleet predicates and completed evidence paths.
- **Verified Sage Wash** (`green-bg`): low-emphasis verified chips and dot halos.
- **Operational Steel** (`steel`): neutral or planned machine state that is neither verified nor risky.
- **Operational Steel Wash** (`steel-bg`): the quiet backing for neutral state marks.

### Tertiary

- **Review Amber** (`amber`): stale evidence, reboot requirements, deferrals, verification-in-progress, or other review states.
- **Ledger Amber** (`amber-curve`): focus outlines, review boundaries, and the restrained footer ledger rule.
- **Review Amber Wash** (`amber-bg`): low-emphasis review chips and dot halos.
- **Exposure Red** (`red`): confirmed exposure, failed execution, script errors, or other action predicates.
- **Exposure Red Wash** (`red-bg`): low-emphasis action chips and dot halos.

### Neutral

- **Provenance Charcoal** (`charcoal`) and **Raised Charcoal** (`charcoal-2`): provenance and footer surfaces only.
- **Warm Ivory Paper** (`paper`) and **Soft Ivory Paper** (`paper-soft`): page ground and subdued evidence backing.
- **Ledger Card** (`card`) and **Ledger White** (`ledger-white`): verdict, map, queue, and ledger surfaces.
- **Forensic Ink** (`ink`) and **Muted Evidence Ink** (`muted`): primary reading text and supporting evidence.
- **Fine Rule** (`line`) and **Strong Rule** (`line-strong`): hierarchy, table dividers, topology connectors, and component boundaries.

### Named Rules

**The Predicate Color Rule.** Green means an observed predicate count is zero or evidence is verified; amber means stale, deferred, reboot, or pending review; red means confirmed exposure, failure, or error; steel remains neutral.

**The Highest Risk Rule.** A verdict rail or topology root inherits the highest actual risk beneath it: red outranks amber, and green is allowed only when every relevant predicate is clear.

**The State-Aware Action Rule.** The principal outlined action inherits red or amber when the verdict requires action or review; otherwise it remains blue.

**The No Decorative Signal Rule.** Semantic color always accompanies factual wording or a numeric predicate and never decorates a surface.

## Typography

**Display Font:** Segoe UI Variable Display, with Aptos Display, Segoe UI, and system UI fallbacks
**Body Font:** Segoe UI Variable Text, with Aptos, Segoe UI, and system UI fallbacks
**Label/Mono Font:** Cascadia Mono with Consolas for machine evidence; compact Segoe UI labels for interface metadata

**Character:** Windows-native type keeps the reports at home in their operating context. Dense display and heading weights establish decisive hierarchy, while modest body sizing, tabular numerals, and mono evidence preserve scan speed without turning the report into a terminal.

### Hierarchy

- **Display:** compact report titles and mastheads; never a marketing hero.
- **Heading:** map, queue, ledger, audit, and provenance section titles.
- **Body:** explanations, evidence summaries, exception reasons, and table content; explanatory copy stays near 68–70 characters when the surface permits.
- **Action:** primary-action and high-priority control labels.
- **Label:** uppercase verdict facts, table headings, run identity, and compact node categories.
- **Technical:** package IDs, versions, timestamps, paths, commands, hashes, and raw evidence.

### Named Rules

**The Evidence Has a Voice Rule.** Proportional type explains a finding; monospaced type shows the machine evidence behind it.

**The Compact Authority Rule.** Use weight and spacing for hierarchy; do not introduce oversized display type or ornamental eyebrow copy.

## Layout

Reports use a centered canvas capped at 1536px with 24px desktop gutters. A 52–54px light evidence header contains the mark, run identity, and print action. The verdict rail follows immediately. Device reports then pair provider topology with the ranked exception queue; fleet reports place estate topology above the prioritized host ledger. On desktop, the ledger begins inside the first viewport.

Search, filters, clear actions, sorting, and live result counts belong inside the ledger panel immediately above the rows they affect. They do not live in the global header. At 820px and below, tables reflow into labeled evidence cards rather than squeezed columns. Fleet nodes become a three-column tablet grid; on mobile they become two columns, with the final fleet node spanning both. Device facts and provider nodes retain two-column groupings where content permits. All meaningful controls have a 44px minimum target at widths up to 820px and for coarse pointers.

Detailed provider, security, runtime, and provenance evidence follows the primary ledger. JavaScript may add filtering, sorting, or collapse long audit detail on screen, but source order, no-script view, and print view remain complete.

### Named Rules

**The Verdict-to-Ledger Rule.** Show the verdict, locate the unhealthy or risky path, act on the ranked exception or host, then verify the complete ledger.

**The First-Viewport Evidence Rule.** Desktop density must expose the ledger before the first scroll without hiding the verdict or topology.

**The Responsive Evidence Rule.** At 820px, tables become labeled cards; on mobile, preserve two-column facts and nodes, with the final fleet node spanning both columns.

**The Complete Artifact Rule.** Progressive controls may improve scanning, but never gate facts, recovery steps, or audit proof from print or no-JavaScript output.

## Elevation & Depth

The system is flat. Evidence panels, verdict rails, nodes, controls, and the light header have no resting shadow. Depth comes from paper tone, one-pixel rules, connector geometry, and compact semantic marks. Charcoal provenance and footer surfaces create a terminal layer at the end of the artifact; they are not a dark chrome band at the top.

### Named Rules

**The Flat Evidence Rule.** Report evidence rests on ruled paper; do not add ambient panel shadows, glass, blur, or gradient depth.

**The State Response Rule.** Motion and lift belong only to direct interaction feedback, and reduced-motion preferences remove transitions entirely.

## Shapes

The final form language is precise and nearly square. Chips use 2px corners, controls and topology nodes use 3px, footer framing uses 4px, and primary surfaces use 5px. Circles are reserved for state marks and verdict symbols. Fine one-pixel borders and topology connectors carry structure.

### Named Rules

**The Tiny Radius Rule.** Content architecture stays within a 2–5px radius range; do not reintroduce 8–14px dashboard cards or pill-shaped containers.

**The Connected Node Rule.** Connector lines and aligned squared nodes must explain a real evidence relationship, not form a decorative chart.

## Components

### Evidence Header

The header is a 52–54px light strip, not a command bar. It carries brand, compact run identity, and an outlined print action. It stays static and flat; on mobile, secondary identity facts yield before core brand and print access.

### Verdict Rail

The compact verdict rail is the report's first decision surface. It uses white evidence paper, a fine rule, 5px corners, text-backed semantic state, essential facts, and one outlined action. The device and fleet root tone reflects the highest actual predicate risk.

### Primary Action

The primary action is outlined and names the next evidence task. It is blue by default, red for confirmed exposure or failure, and amber for review or pending states. At 820px and for coarse pointers it has a 44px minimum target.

### Health-Map Root and Node

Device reports connect the host root to provider nodes derived from grouped report rows. A provider is red when a grouped row needs action, amber when it changed or remains planned/reviewable, and green when checks are verified; additional provider groups collapse only into a neutral “Other providers” node while their full evidence remains below.

Fleet reports connect the estate root to five keyboard-operable risk-filter nodes. Security, Execution, and Lifecycle turn red when their confirmed predicate counts are non-zero; Currency and Completion turn amber for stale/review or reboot counts; every zero count is verified green. Selecting a node filters the host ledger and selecting it again clears the filter.

### Ranked Exception Queue

The device queue orders operator tasks deterministically by confirmed exposure and execution impact. Squared numbered markers, concise evidence-led wording, and direct package or security links keep recovery actionable. Red is reserved for confirmed action; review states use amber.

### Evidence Ledger

The device package verification ledger and fleet prioritized host ledger keep tabular numerals, sticky sortable headings, text-backed status chips, evidence disclosure, and explicit result announcements. Search, filters, clear actions, and result counts are colocated in a quiet ruled toolbar directly above the rows. Fleet order is security exposure first, failed/error/deferred execution second, stale/lifecycle/reboot review third, then healthy hosts. At 820px, each row becomes a labeled evidence card with the same data and no horizontal page overflow.

### Status Indicators

State dots, chips, row rules, words, and counts work together; color is never the sole carrier. Verified, review, action, and neutral/planned treatments use the semantic palette documented above. Filter result counts are announced through polite live regions.

### Provenance and Footer

Charcoal appears in the deeper provenance/evidence block and footer, where it marks the document's terminal proof layer. It must not migrate back into the header.

### Audit Disclosure

Technical detail is expanded in the document by default. JavaScript may collapse the audit appendix after load, but filtering expands relevant evidence, no-script CSS preserves all content, and print forces disclosure open.

### WinForms Prompt

Interactive native prompts preserve the same charcoal, ivory, blue, green, amber, and red logic without inventing web components. They use Segoe UI, DPI autoscaling from 96 DPI, a sizable 640×420px default window with a 560×400px minimum, 44px minimum actions, Windows High Contrast system colors, accessible names, scrollable read-only technical evidence, focus transfer when detail opens, and a live visible timeout that states when automatic deferral will occur.

## Do's and Don'ts

### Do:

- **Do** lead with the verdict, expose the broken or risky evidence path, provide the next action, and preserve the complete ledger.
- **Do** keep the header light, 52–54px high, and limited to identity, run facts, and print.
- **Do** bring the package or host ledger into the first desktop viewport.
- **Do** colocate search, filters, sorting, clearing, and result feedback with the ledger they operate on.
- **Do** use outlined state-aware actions and preserve the 44px target floor at 820px and for coarse pointers.
- **Do** reflow tables into labeled evidence cards at 820px and preserve mobile two-column facts and nodes, with the final fleet node spanning.
- **Do** derive every node and root tone from actual predicates, with red outranking amber and zero-risk nodes shown as verified green.
- **Do** keep the device provider map, ranked exception queue, package ledger, fleet five-node risk map, and prioritized host ledger semantically aligned.
- **Do** preserve search, filters, sorting, links, keyboard focus, status announcements, forced colors, reduced motion, print, and no-JavaScript completeness.
- **Do** keep reports self-contained, dependency-free, offline, and free of page-level overflow.
- **Do** keep native prompts DPI-aware, High-Contrast-aware, explicit about deferral, and capable of revealing complete technical evidence.

### Don't:

- **Don't** restore obsolete status strips or replace the topology with generic metric-card dashboards.
- **Don't** use charcoal as the command header; reserve it for provenance and footer material.
- **Don't** use red for unknown, stale, deferred, reboot, or merely unverified evidence; those states are amber unless a confirmed failure or exposure predicate also exists.
- **Don't** hide facts, recovery actions, provider evidence, or audit proof behind JavaScript-only disclosure.
- **Don't** add gradients, glass, decorative charts, thick accents, entrance animation, resting shadows, remote assets, or oversized rounded containers.
- **Don't** separate search and filters from their evidence ledger.
- **Don't** squeeze tables into unreadable mobile columns or permit page-level horizontal scrolling.
- **Don't** invent native prompt components or behaviors that are not present in the WinForms implementation.
