# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

**Primary: two rivals.** Two people who already wear an Apple Watch and close
their rings, and who want a private, week-long head-to-head with one specific
person: a friend, partner, sibling or coworker. (Confirmed by the owner,
2026-11-12.)

Secondary, supported but not the centre of gravity: small groups of three or
four playing a group match, and one person playing a bot.

## Product Purpose

HealthComp runs private seven-day Activity matches between people, scored from
Apple's Activity rings: 1 point for every 1% of each ring, up to 600 a day.

It is built on top of Apple Fitness and exists to do the competition part
better than Fitness does: a more fun vibe, a richer interface, richer data,
history, a rivalry record, and more than one type of match. (Owner's words,
2026-11-12.)

Undecided: what success is measured by (no metric or goal has been set).

## Positioning

Apple Fitness supplies the rings; HealthComp supplies the rivalry. The same
week of Activity becomes an event with a build-up and a verdict, and the weeks
add up to a record between two people that Fitness does not keep. No single
feature carries the position; it is the combination of fun, richness, history
and match formats on top of data the user already trusts.

## Operating Context

- An iPhone app, with a read-only Apple Watch scoreboard, Home Screen widgets, a
  Live Activity and notifications.
- Activity comes from HealthKit. No special workout is needed; closing rings as
  usual is playing.
- A match starts from a challenge: a private link or a friend in the app. It
  runs seven days and ends with a verdict.
- A small website carries the invite and challenge link landing pages, privacy
  and support.
- Invitation-only beta. Not publicly released; the website's landing page says
  "Coming soon to iPhone".

## Capabilities and Constraints

Shipped today:

- One-on-one matches, and group matches: three-way, four-way and doubles (2v2).
- Bots that fill a seat or serve as practice: Pacer, Chill, Erratic, Beast.
- Friends, search, challenge links, player profiles with photos.
- A versus intro when a match is accepted; an end-of-match judges' decision;
  result and recap screens; a shareable result image.
- The belt: a title held between two people, with title defences and earned or
  lost ceremonies.
- History, personal records, badges, ring-by-ring head-to-head.
- Automated banter, reactions, sounds at big moments with a volume setting.

Binding rules (confirmed by the owner, 2026-11-12):

- **Health data stays on the phone.** Raw HealthKit data never leaves the
  device; only computed scores sync. Health access is read-only.
- **iPhone in portrait; the watch is read-only.** No iPad or landscape layouts.
  The watch is a scoreboard to read, not a place to create or manage matches.
- **One job per screen.** Minimal copy; detail goes into pushed screens, sheets
  and ••• menus.
- **Colour means you.** Ring colours and amber are only ever the viewer's own;
  the opponent and all structure stay neutral. The existing Theme tokens are
  kept and no new colours are added.

Earlier owner decisions that still stand:

- The belt is one-on-one only. Group matches never move it or count as a
  defence. (2026-11-09)
- In a group match the creator sets format, players, teams and bots; the match
  starts only once every seat has accepted. (2026-11-09)
- No stakes or wagers. (Rejected, November 2026)
- Installed builds must keep working: server changes are additive.
  (2026-11-10)
- The existing visual style is kept and raised in fidelity, not replaced.
  (November 2026)

Terminology the app uses with people: match (the code says competition),
challenge, challenge link, rings (Move, Exercise, Stand), points, belt, title
defence, judges' decision, records, badges.

Technical floor: iOS 17, watchOS 10.

Undecided: languages other than English; any iPad or Mac presence beyond the
rule above; a public launch date.

## Brand Commitments

- Name: HealthComp.
- The match is framed as a title fight: days are rounds, there is a judges'
  decision, the belt is a title. The framing is inspired by fight promotion and
  uses original art and wording only: no real promotion's name, logo or cage,
  and no real announcer's name or catchphrases. The owner cleared the belt and
  title language and the ceremony art for trademarks on 2026-11-08.
- Approved ceremony copy: "AND NEW", "AND STILL".
- Voice: dry and deadpan, never mean. Shipped banter sets the tone, for example
  "You have 82% of your team's points. A permit may be required."
- Copy is kept minimal.

## Evidence on Hand

- The shipped app and watch app in this repository are the visual truth:
  `HealthComp/`, `HealthCompWatch/`, `HealthCompWidgets/`, with the palette in
  `HealthComp/App/Theme.swift`.
- Original belt art in `HealthComp/Resources/Belt`, sounds in
  `HealthComp/Resources/Sounds`, app and launch marks in
  `HealthComp/Resources/Assets.xcassets`.
- Website pages in `web/`, including `web/og.png`.
- Support and privacy copy in `web/support.html` and `web/privacy.html`.

Not on hand, and not to be invented: testimonials, user or match counts, press,
pricing, an App Store listing, screenshots approved for marketing.

## Product Principles

1. **The pair comes first.** Every screen serves two specific people and the
   history between them before it serves groups or strangers.
2. **A week of rings is an event.** The fun is the product; the data is already
   Apple's.
3. **Richer than Fitness, never busier.** History, records and the rivalry
   ledger are first-class, and each still gets its own screen.
4. **Private by construction.** Nothing about a person's health leaves their
   phone except a score they chose to compete with.
5. **Colour means you.** A person can find themselves on any screen at a glance.

## Accessibility & Inclusion

No product-specific standard has been set by the owner. Existing practice in
the code, to be preserved until one is: text on amber is darkened in light mode
to hold 4.5:1 contrast, and layouts are tested at the largest accessibility
text size.
