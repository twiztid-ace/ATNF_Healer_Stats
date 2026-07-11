# ATNF Healer Analysis — Design System

Reuse these exact tokens for every new page. Don't reinvent the palette per healer —
consistency across the site matters more than novelty at this point.

## Concept

A combat-log "ledger" — an apothecary/cartographer's logbook feel rather than a
generic dashboard. Deep ink-teal ground, warm parchment page surface, copper accent.

## Color tokens

```css
:root{
  --ink: #132A2C;              /* deep teal, body background + primary text on parchment */
  --ink-2: #1C3A3D;             /* slightly lighter ink, used for target-bar fills etc */
  --parchment: #F3E9D6;         /* page surface */
  --parchment-dim: #E8DBC2;     /* secondary surface (track backgrounds) */
  --copper: #C97A3D;            /* primary accent — links, highlights, active states */
  --moss: #5F7A52;              /* positive/good status (checkmarks, "on target") */
  --rust: #B5503A;              /* negative/attention status (missing items, high overheal) */
  --gold: #D9B25C;              /* rank/percentile highlight, left-border accent on notes */
  --line: rgba(19,42,44,0.16);  /* hairline dividers */
}
```

IMPORTANT: no letter-grade color-coding (red/yellow/green grade badges). Percentile
numbers only. The seal/badge element uses `--copper` stroke, not alarm colors, even
for low percentiles — the finding itself carries the information, the container
shouldn't editorialize with alarm red.

## Typography

- **Display (headers)**: Cormorant Garamond, serif, weight 600-700. Used for h1/h2 and
  the percentile number in the seal badge.
- **Body**: Inter, sans-serif, weight 400-500. Everything else.
- **Data/utility**: IBM Plex Mono, monospace. All numbers, stats, timestamps, report
  codes, eyebrow labels. This is what makes stats feel like ledger entries rather than
  UI chrome.

Import once per page:
```css
@import url('https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,500;0,600;0,700;1,500&family=Inter:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap');
```

## Layout conventions

- Page container: `max-width: 880px` (boss/raid pages) or `720px` (list/picker pages),
  centered, `background: var(--parchment)`, `border-radius: 4px`,
  `box-shadow: 0 30px 80px rgba(0,0,0,0.45)`.
- Body background: `var(--ink)` with two subtle radial gradients (copper + gold at low
  opacity) for ambient texture — not a flat color.
- Sections divided by hairline `border-bottom: 1px solid var(--line)`, not cards/boxes.
- Numbered section markers (`01`, `02`, `03`) in IBM Plex Mono, copper — used because
  the sections genuinely are a sequence (scorecard → spells → targets), not decoration.
- Back-navigation links go in the eyebrow line at the top of the header
  (`← All raids`, `← All healers`), copper, no underline.

## Signature element: the wax-seal percentile badge

An SVG circle (double ring, one solid + one dashed) containing the percentile number
in Cormorant Garamond, with "PERCENTILE" in small-caps IBM Plex Mono beneath it inside
the same circle. This is the one bold, memorable element — keep everything else quiet.

```html
<svg class="seal" viewBox="0 0 120 120">
  <circle cx="60" cy="60" r="56" fill="none" stroke="#C97A3D" stroke-width="2"/>
  <circle cx="60" cy="60" r="48" fill="none" stroke="#C97A3D" stroke-width="1" stroke-dasharray="2 4"/>
  <text x="60" y="66" text-anchor="middle" font-family="Cormorant Garamond, serif" font-weight="700" font-size="26" fill="#132A2C">{{PERCENTILE}}</text>
  <text x="60" y="82" text-anchor="middle" font-family="IBM Plex Mono, monospace" font-size="9" letter-spacing="0.05em" fill="#132A2C" opacity="0.6">PERCENTILE</text>
</svg>
```

## Comparison bars (spell composition, target distribution)

Two-row pattern per item: character's bar (solid `var(--copper)` fill) directly above
the benchmark's bar (dim `rgba(19,42,44,0.25)` fill), both against a
`var(--parchment-dim)` track. Legend with colored dots above the list.

## Checklists (gear audit)

Row pattern: small circular icon (✓ on `var(--moss)` background, ! on `var(--rust)`
background) + description + right-aligned mono note. Dashed `var(--line)` divider
between rows, none on the first.

## Callout notes

`.coverage-note` pattern: small text, muted ink color, `border-left: 3px solid
var(--gold)`, left padding. Used for the one or two sentences of actual interpretation
per section — where the real insight lives, not just raw numbers.

For a raid-wide finding that needs more visual weight than a coverage-note (e.g. the
"zero Healing Stream Totem across all 10 kills" finding), use a
`.consistency-banner` instead: rounded box with a colored circular icon on the left
(moss for a confirmed-good finding, rust for a flagged issue) and bolded lead-in text.
