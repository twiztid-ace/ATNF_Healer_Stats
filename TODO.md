# TODO

Working task list for this repo. See `CLAUDE.md` and `WORKFLOW.md` for full
context on any item below — this file is just the punch list, not the
explanation. Keep entries short; move finished items out rather than
checking them off and leaving them here.

## Open

- [ ] **Roll the Gruul's Lair/Magtheridon's Lair addition out to the other 3
      healers.** Only Danceswtrees (Druid, report `LKbVcNfRxyBkj2mg`) has an
      actual raid night pulled and rendered against the expanded boss list so
      far (2026-07-15). Vajomee (Shaman), Lippies (Priest), and Crowns
      (Paladin) haven't had a new raid night generated since the tier was
      added. Nothing to migrate by hand — the next `generate-healer-report`
      run for any of them picks up the new boss IDs automatically — but don't
      assume their sites already reflect this until it's actually been run.
- [ ] **Spot-check whether the OffHand missing-enchant false positive already
      appears in the 4 original hand-written v2 sites.** Fixed 2026-07-15 in
      `scripts\lib\ReportRenderLib.psm1` (OffHand removed from
      `$script:EnchantableSlotIndexes` — every tracked healer spec holds a
      non-weapon Held-In-Off-Hand item there, which can't carry a permanent
      enchant in this era regardless of what's equipped). Danceswtrees's,
      Vajomee's, Lippies's, and Crowns's original real v2 pages predate the
      render pipeline and were hand-written by Claude, so this fix never
      touched them — worth a pass if a gear-audit accuracy review is ever
      done on those pages specifically.
- [ ] **Exercise the new real-wipe denominator path at least once.** The
      2026-07-15 fix to `render_healer_report.ps1`/`update_hub_pages.ps1`
      (deriving "bosses killed" from real fight data instead of a hardcoded
      `-TotalBosses` tier constant) has only been verified on a no-wipe report
      (Danceswtrees's 12/12 real kills). The `<kills>/<attempted>` branch —
      shown only when a real wipe is present in a report's own data — is
      still unexercised against real data; confirm it renders correctly the
      next time a report with a genuine wipe comes through.
- [ ] **Tranquility's guid is still unknown/unobserved** (Druid-only concept).
      `$cooldownGuids["Tranquility"]` is an empty array in every Druid-touching
      script and will silently show 0 forever until the real guid is seen and
      added once someone actually casts it in a pulled report.
- [ ] **Confirm Magtheridon's Lair kills actually get attempted/logged** for
      at least one real healer report (all four classes have real Top 100
      *benchmark* data for it already — see CLAUDE.md's "Recently closed" —
      but no real character report has included a Magtheridon kill yet, only
      Gruul's Lair's Maulgar/Gruul so far via Danceswtrees).
- [ ] **Real re-pull needed to backfill correct Battle/Guardian Elixir data.**
      2026-07-15: fixed a real, systemic bug where every one of the 5 pull
      scripts labeled ANY elixir as a "Flask" (`-match 'Flask|Elixir'`, first
      match wins) — confirmed on real data that "Elixir of Draenic Wisdom"
      (a Guardian Elixir) was mislabeled as a flask on every already-pulled
      report across all 4 healers, and the same bug corrupted the
      `Top100FlaskActivePct` Top 100 benchmark stat for all 4 classes. Fixed
      at the root (`Get-ConsumableClassification` in `scripts\lib\WclV2Api.psm1`,
      used by all 5 pull scripts now) — but this only affects pulls going
      forward. Every already-pulled report's raw `*_consumables.json` (7 real
      character folders) and every class's Top 100 benchmark sample (~4,000
      parses across 4 classes) still reflects the old conflated data and has
      no way to distinguish a real Battle Elixir from a Guardian Elixir
      without a real re-pull (the old pull only ever captured ONE
      elixir/flask match total, discarding the rest). This is a genuinely
      costly action (real, rate-limited WCL API calls across a lot of
      parses) — needs an explicit decision on scope (just Danceswtrees's
      current report? all 7 real character reports? the full Top 100
      benchmark re-pull for all 4 classes too?) before running it.
- [ ] **New same-raid healer-rank features (2026-07-15) have only been
      verified on Danceswtrees's report.** Two independent, real, mechanical
      comparisons against the OTHER tracked-spec healers (Resto Druid/Shaman,
      Holy Priest/Paladin) in the SAME raid on the SAME fight:
      - **iLvl Healing Rank** — WCL's own real "HPS Performance Comparison
        (By Item Level)" metric (`rankPercent`/`bracketData`/`totalParses` in
        `{code}_v2_rankings.json` — already fully captured for every
        already-pulled report, no re-pull was needed for this one).
      - **Raw Healing Rank** — ranked by real raw total healing done instead
        (`table(dataType: Healing)`'s own `total` field, per player, per
        fight). This one DID need new capture: `pull_character_TEMPLATE.ps1`
        now persists every tracked-spec healer's row into
        `{label}_activetime.json`'s `sameRaidHealersRawHealing` (previously
        discarded entirely except the audited character's own row) —
        Danceswtrees's existing 12 fights were backfilled with a real,
        one-time re-pull the same session (confirmed cheap: 12 real API
        calls, reusing a query already being made). The two metrics can have
        different real populations per boss (different WCL endpoints,
        confirmed on Maulgar: 5 tracked healers for the ilvl metric vs 4 for
        raw healing) — this is real, not a bug to reconcile away.
      - Both show on the raid overview (two new columns + two raid-wide
        summary sentences) and on every boss page (two more "seals" next to
        the existing percentile one, each independently omitted when no
        other tracked healer was present for that specific metric). Only
        exercised against Danceswtrees's 12-boss report so far — worth a
        second real data point (a raid with a genuinely different same-raid
        roster, and ideally one where the audited character doesn't rank #1
        on either metric) before trusting the rendering in every case.
      - **Vajomee/Lippies/Crowns's existing reports don't have
        `sameRaidHealersRawHealing` in their `*_activetime.json` files yet**
        — same backfill treatment as Danceswtrees would be needed before
        Raw Healing Rank can show on their existing pages (iLvl Healing Rank
        already works for them with no changes needed, per the point above).

## Known, accepted limitations (not being chased further)

- No `combatantinfo` snapshot within the 2-minute backward buffer for a
  handful of parses per class (likely late-joining players) — Druid ~0.1%,
  Shaman ~0.5%, Priest ~1.1%, Paladin ~1.1%. Reported as a per-player
  consumables-data gap, not investigated beyond that.
- Power Word: Shield's Top 100 benchmark usage is a real but misleading ~0%
  on 9 of 10 SSC/TK bosses (ranking-metric bias, not a real usage norm) —
  mechanically auto-tagged as the `priest_pws_benchmark_bias` canned caveat
  by `build_boss_analysis.ps1` for any report built through the render
  pipeline; still worth remembering when hand-authoring findings.json prose.
- Holy Shock's cast (guid 33072) and its heal (guid 33074) are different real
  guids — mechanically auto-tagged as the `paladin_holy_shock_guid_split`
  canned caveat the same way. Don't claim Holy Shock "doesn't heal" for a
  Paladin; the wider Top 100 sample shows real landed heals under the second guid.

## If a fifth class is ever added

Playbook proven four times over now (Druid, Shaman, Priest, Paladin) — see
CLAUDE.md's "Explicitly open" item 2 for the full 5-step checklist. Short
version: real-data discovery pass first (never assume a class's cooldown kit
or self-buff-uptime concept from memory, and don't over-generalize a finding
scoped to one character's report before checking it against the full Top 100
sample), then build the pull script / template / analysis-table entries
following the existing four classes' structure, not their specific content.
