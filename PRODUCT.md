# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary users are Windows endpoint and IT administrators reviewing patch posture, security exposure, and remediation evidence across individual devices or an estate. Interactive device users encounter only the native prompts when an application blocks verification or a run completes.

## Product Purpose

PatchManager discovers, applies, verifies, and reports Windows and application updates. Success means an operator can identify the highest-risk host or package, understand the next action, and retain complete audit evidence without manually reconciling multiple patch providers.

## Positioning

PatchManager treats verification evidence as the product: patch actions, version confirmation, security exposure, lifecycle status, deferrals, and provider coverage are preserved in self-contained per-device reports and rolled into a fleet view.

## Operating Context

The product runs on Windows 10/11 through Windows PowerShell 5.1, both interactively and through Task Scheduler. It generates offline HTML reports for human review, JSON and CSV for automation and SIEM workflows, and a fleet dashboard from the newest JSON report in each host folder on a local or UNC share. WinForms dialogs are shown only in interactive sessions.

## Capabilities and Constraints

- Preserve command-line parameters, configuration schema, report JSON schema, CSV columns, exit codes, and provider behavior.
- HTML reports must remain self-contained, dependency-free, printable, and complete without JavaScript.
- The UI implementation remains native PowerShell/WinForms and generated HTML/CSS/JavaScript; no frontend framework is introduced.
- Reports may contain clean, attention, deferred, stale, malformed, empty, emergency, dry-run, report-only, and inaccessible-share states.

## Brand Commitments

Keep the PatchManager name, canonical shield-and-ledger mark, charcoal/ivory identity, and the line “Patch. Verify. Prove it.” Use direct evidence-led language: applied, verified, blocked, failed, pending, source, report, and proof. Avoid hype or unsupported claims.

## Evidence on Hand

The repository contains generated device and fleet reports, representative JSON fixtures, desktop and mobile screenshots, WinForms prompt screenshots, a brand guide and canonical SVG assets, and static tests covering report semantics and behavior. No testimonials, customer logos, or commercial performance claims are available and none should be invented.

## Product Principles

- Lead with posture, then required action, then full proof.
- Never hide or weaken audit evidence to simplify the screen.
- Keep automated operation quiet while making interactive decisions explicit.
- Make safety states and deferrals distinguishable from verified success.
- Preserve offline and print usability as first-class behavior.

## Accessibility & Inclusion

Target WCAG 2.2 AA for generated reports. Support keyboard-only operation, visible focus, semantic status announcements, reduced motion, Windows High Contrast, and 200% DPI/font scaling for native prompts.
