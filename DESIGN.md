---
name: HealthComp
description: Private seven-day Activity matches, staged like a title fight.
colors:
  move: "#E4003A"
  exercise: "#009A4E"
  stand: "#0072BC"
  you: "#8F5C00"
  you-dark: "#F2A100"
  you-fill: "#F2A100"
  on-you-fill: "#111111"
  ink: "#111111"
  ink-dark: "#F5F5F0"
  on-ink: "#FAFAF7"
  on-ink-dark: "#0F0F10"
  ground: "#FAFAF7"
  ground-dark: "#0F0F10"
  secondary: "#5E5E62"
  secondary-dark: "#A3A3A8"
  tertiary: "#66666B"
  tertiary-dark: "#8E8E93"
  faint: "#B8B8B2"
  faint-dark: "#48484D"
  panel: "#EFEFEA"
  panel-dark: "#19191B"
  control: "#E6E6E0"
  control-dark: "#222225"
  hairline: "#DEDED8"
  hairline-dark: "#2C2C30"
  track: "#E2E2DC"
  track-dark: "#26262A"
  outline: "#CFCFC9"
  outline-dark: "#3A3A40"
  belt-well: "#0F0F10"
  belt-well-dark: "#19191B"
typography:
  display:
    fontFamily: "SF Pro Compressed, system-ui, sans-serif"
    fontSize: "56px"
    fontWeight: 800
    lineHeight: 1
    fontFeature: "tnum"
  headline:
    fontFamily: "SF Pro Condensed, system-ui, sans-serif"
    fontSize: "34px"
    fontWeight: 800
    lineHeight: 1.2
  title:
    fontFamily: "SF Pro Condensed, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 800
    lineHeight: 1.25
  body:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.33
  label:
    fontFamily: "SF Pro Condensed, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1.38
    letterSpacing: "1.2px"
rounded:
  chip: "8px"
  control: "14px"
  panel: "20px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.on-ink}"
    rounded: "{rounded.control}"
    padding: "12px 18px"
    height: "54px"
  button-secondary:
    backgroundColor: "{colors.control}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "12px 18px"
    height: "54px"
  button-quiet:
    textColor: "{colors.secondary}"
    height: "44px"
  panel:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.panel}"
  section-label:
    textColor: "{colors.ink}"
    typography: "{typography.label}"
---

# Design System: HealthComp

## Overview

**Creative North Star: "The Scoreboard"**

HealthComp looks like the board above an arena. Numbers are the heroes: heavy,
compressed numerals sized to be read across a room, under condensed capital
labels. Everything that is not a number is flat and neutral, a page tone and a
panel tone one step apart, so the board never competes with the score. Colour
is rationed to a single meaning: it is you. Your rings keep Apple's Move,
Exercise and Stand hues; your score, name and wins are amber; your opponent and
every piece of structure are ink and grey.

The mood is sporty and bold. Weight is heavy, edges are firm, type is
condensed, and the mark's 12-degree slash runs through bars, splits and
transitions as the line between you and them.

It is not an Apple Fitness clone: no black field of glowing concentric rings as
the main visual. And it is not licensed fight branding: the title-fight framing
uses original art and wording only, never anything that reads as a real
promotion's graphics.

**Key Characteristics:**
- Heavy compressed score numerals over condensed capital labels.
- One accent, amber, and it always means the viewer.
- Flat surfaces; depth comes from tone, not shadow.
- The 12-degree slash as the recurring divider and the origin of motion.
- System typeface only (SF Pro in its compressed and condensed widths).
- Light and dark are both first-class; the watch is always dark.

## Colors

A neutral warm-grey board with one amber voice and Apple's three ring hues.

### Primary
- **Your Amber** (`you`, `you-dark`, `you-fill`): the viewer's score, name, wins
  and side of any split. As text it darkens in light mode to hold 4.5:1; as a
  fill it stays bright in both modes and carries `on-you-fill` content.

### Secondary
- **Move Red** (`move`), **Exercise Green** (`exercise`), **Stand Blue**
  (`stand`): the viewer's own ring detail, and the three bars of the mark.
  Never used for an opponent, a status or decoration.

### Neutral
- **Ink** (`ink`): primary text, the opponent, and neutral primary buttons.
- **Ground** (`ground`): the page, and the navigation bar so each screen reads
  as one surface.
- **Secondary** and **Tertiary** (`secondary`, `tertiary`): supporting text.
- **Panel** (`panel`): cards and grouped rows, one tone off the ground.
- **Control** (`control`): secondary buttons and a pressed row.
- **Hairline**, **Outline**, **Track**, **Faint** (`hairline`, `outline`,
  `track`, `faint`): dividers, strokes, empty bar tracks and placeholders.
- **Belt Well** (`belt-well`): the dark stage behind belt art in both modes.

### Named Rules
**The Colour Means You Rule.** Ring hues and amber are only ever the viewer's
own. The opponent and all structure stay neutral. No new colours are added.

**The Neutral Action Rule.** Primary buttons are ink, not amber. Colour is not
spent on calls to action.

## Typography

**Display Font:** SF Pro Compressed, heavy (system)
**Body Font:** SF Pro (system)
**Label Font:** SF Pro Condensed, bold (system)

**Character:** One family at three widths. Compressed carries the score,
condensed carries structure, regular carries sentences. Nothing is bundled;
everything is a Dynamic Type text style.

### Hierarchy
- **Display** (heavy, compressed, 28 to 96pt by context, tabular figures):
  scores and the verdict. Sized with `@ScaledMetric` so it still follows
  Dynamic Type.
- **Headline** (heavy, condensed, large title): the one big statement on a
  result or ceremony screen.
- **Title** (heavy, condensed, title 3): names and row leads.
- **Body** (regular, subheadline, with callout and caption as steps down):
  sentences and supporting detail.
- **Label** (bold, condensed, footnote, 1.2pt tracking, capitals): section and
  status labels. The most used style in the app.

### Named Rules
**The Three Widths Rule.** Compressed for numbers that are scores, condensed
for labels and names, regular for prose. A width is never chosen for looks.

**The Scaled Score Rule.** Fixed-size score numerals go through `@ScaledMetric`
relative to a text style. No bare point sizes for text.

## Layout

iPhone in portrait only. One navigation stack rooted at Home, with no tab bar;
each screen does one job. Detail lives in a pushed screen, a sheet (large, or
medium then large) or a ••• menu, and the one primary action is pinned.

Spacing sits on a 4pt base. 16 is the page gutter and the default panel
padding; 12 and 8 are the working gaps inside a panel; 20 and 24 separate
sections. Panels span the full width inside the gutter. Layouts are checked at
the largest accessibility text size.

## Elevation & Depth

Flat. Depth is carried by tone: a panel is one step off the ground, a control
one step off the panel, and a hairline separates rows inside a panel. Bars are
opaque in the ground colour with no shadow line.

### Named Rules
**The Flat Board Rule.** No shadows on everyday screens. Glow and flash are
allowed only inside the set pieces: the versus intro, the judges' decision and
the belt ceremonies.

## Shapes

Continuous-corner rectangles at three sizes: panels (20), buttons and controls
(14), and small chips and thumbnails (8). Avatars are circles, with an amber
ring on the viewer's own. Against those soft containers the signature shape is
hard: the slanted bar, a parallelogram cut at the mark's 12 degrees, whose
neighbours leave a slash-shaped gap. The mark itself is three ring-coloured
bars facing one ink block across that slash.

## Components

The intended feel is **tactile and punchy**: a control should feel physical and
satisfying to hit. The shared button styles answer a press with an opacity
dip, a small scale and a light haptic tap.

### Buttons
- **Shape:** continuous rounded rectangle (14), full width, 54 minimum height.
- **Primary:** ink fill, on-ink condensed headline label, 18 by 12 padding.
- **Secondary:** control fill, ink label, same geometry.
- **Quiet:** text only in secondary grey, 44 minimum height, for rare and
  destructive actions.
- **Pressed / Disabled:** opacity 0.8 and scale 0.97 (no scale under Reduce
  Motion) over 140ms ease-out, with a light impact haptic; disabled 0.45.
- **Busy:** the label stays and dims; a spinner replaces it only after 200ms.
- **Press card:** tappable cards scale to 0.96 on press, skipped under Reduce
  Motion.

### Cards / Containers
- **Corner Style:** continuous, 20.
- **Background:** panel tone on the ground.
- **Shadow Strategy:** none (see Elevation & Depth).
- **Border:** none; hairlines only between rows inside a panel.
- **Internal Padding:** 16.
- **Rows:** a pressed row fills with the control tone in place; rows do not
  scale, which would break the panel's edge.

### Inputs / Fields
- System text fields and toggles.
- Segments are the app's own (`CompetitionSegments`): a control-tone track
  with a ground-tone thumb outlined in `outline`, since ground on control is
  only 1.2:1. The selected label is heavy ink, the others semibold secondary
  (5.2:1 light, 6.3:1 dark). The thumb moves with Settle.

### Navigation
- Opaque ground-coloured bar with no shadow line, inline titles, ink text.
  Rare actions sit in a ••• menu; sheets use system detents.

### Section Label
- Condensed bold footnote in capitals with 1.2pt tracking, ink, marked as a
  header for VoiceOver.

### Score Numerals
- Compressed heavy tabular figures. A changing score rolls digit by digit; under
  Reduce Motion it cross-fades.

### Motion
- **Grow** (450ms, one overshooting curve): length or possession changing
  once. Geometry only, never colour. The only overshoot in the system.
- **Settle** (300ms, no bounce): anything live that moves or resizes.
- **Fade** (200ms ease-out): appearance only, and what motion becomes under
  Reduce Motion.
- **Press** (140ms ease-out): touch.
- **Late** (150ms after a 200ms wait): anything that arrives after its cause.
- Grow and settle land on their final state under Reduce Motion and when the
  display is dimmed.

## Do's and Don'ts

### Do:
- **Do** keep colour for the viewer: ring hues for their rings, amber for their
  score, name and wins.
- **Do** make the number the largest thing on the screen, in compressed heavy
  tabular figures.
- **Do** build surfaces from ground, panel and control tones with hairlines.
- **Do** use the Theme tokens, `SectionLabel`, `themePanel` and the three button
  styles before making a new one.
- **Do** choose motion from the five named animations by what changed.
- **Do** give every moving piece a still state for Reduce Motion.
- **Do** make controls feel tactile and punchy when refining them.

### Don't:
- **Don't** colour an opponent, a status or a button with ring hues or amber.
- **Don't** add a colour that is not in the Theme.
- **Don't** add shadows to everyday screens.
- **Don't** make glowing concentric rings on black the main visual.
- **Don't** use anything that reads as a real fight promotion's graphics, name,
  logo or catchphrases.
- **Don't** set text in a bare point size.
- **Don't** add a second overshooting curve.
