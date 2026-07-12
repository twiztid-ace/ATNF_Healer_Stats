# Druid v2 pipeline — TODO / known issues

Living tracker for bugs and open work on the enhanced (v2, events-based) Druid
pipeline specifically. Not a duplicate of WORKFLOW.md's gotcha list — cross-references
it where relevant, but this file is for *tracking status* (open/in-progress/done),
WORKFLOW.md stays the deep explanation of *why*. Update this as items get fixed or
new ones get found — don't let it go stale.

## Requested, not started

(empty right now — see "Active Time" below for the item that used to live here)

## Active Time — resolved, better than expected (2026-07-12)

- [x] **Brought back "Active Time" as a real 5th Scorecard stat, with a real
      Top 100 comparison (top1/avg/median, same pattern as HPS/HPM).** Dropped
      2026-07-11 on the stated premise that no event carries an equivalent field
      once healing/casts moved off the healing TABLE - that premise was never
      actually tested. Investigated per the project's "test one real thing
      before guessing" rule: Step 0 was to check whether the healing TABLE's
      top-level per-player `activeTime`/`activeTimeReduced` scalars (as opposed
      to its truncation-prone nested `abilities[]` array - the actual reason the
      endpoint was abandoned) still worked. They do - pulled it live for
      Danceswtrees's real Hydross kill and got `activeTime=138449ms/143007ms
      =96.8%`, exactly matching the number already recorded on the
      pre-events-rewrite v1 page, and cross-validated `total`/`overheal` on the
      same response against the events-based numbers (also exact match). This
      made the events-based GCD-reconstruction fallback (mixing real
      begincast→cast measured time with an assumed flat 1.5s GCD for instant
      casts - an estimate, not exact data) unnecessary. Same "test before
      assuming it's gone" pattern that resurrected HPM.
      **Built into the pipeline the same day:** both `pull_top100_druid.ps1`
      and `pull_character_TEMPLATE.ps1` now fetch this via one extra table call
      per parse/fight (same shape as the existing `deaths` call), saved as
      `*_activetime.json`. Backfilled for Danceswtrees's 10 already-pulled boss
      kills (`scripts/backfill_activetime_danceswtrees.ps1`) and all ~1,000
      already-active Druid Top 100 parses (`scripts/backfill_activetime_top100_druid.ps1`,
      RunspacePool-parallelized, `-MaxThreads 10`) - both one-off scripts, not
      part of the recurring pipeline (new parses get it inline going forward).
      The Top 100 backfill's first run hit a real encoding bug: reading
      `manifest.json` without `-Encoding UTF8` mangled every non-ASCII player
      name (Chinese/Korean/accented Latin) into mojibake, silently failing the
      later name-match against the healing table response (21/100 failures in
      the first batch, all non-ASCII names, 0 ASCII-name failures) - the exact
      BOM/encoding gotcha class CLAUDE.md already flags. Fixed by matching
      `pull_top100_druid.ps1`'s existing convention (`-Encoding UTF8` on every
      manifest read); rerun completed with 0 failures.
      `summarize_class_benchmarks.ps1` computes `ActiveTimePct` per parse (same
      pattern as HPM - `$null`/excluded if the file is missing, e.g. not yet
      backfilled) and adds `ActiveTime_Top1`/`_Top100Avg`/`_Median`/
      `_SampleUsed` to `benchmark_summary.csv`. `boss_page_template_druid.html`'s
      Scorecard is back to 5 stats (`.stat-grid-5`): HPS, Overheal, Effective
      healing, Active time, Raid deaths (kept, not replaced). WORKFLOW.md
      updated (the old "no equivalent field" claim corrected in 3 places).

## Real bugs found while building the Leotheras page (2026-07-12)

- [x] **Fixed: `begincast` events were double-counting cast-time cooldowns and
      inflating their self%.** Found while building Danceswtrees's Leotheras page
      — her one real Rebirth cast (on Captinspanky) was showing as 2 events, one
      of them marked "self." Root cause: WCL logs a separate `"type":"begincast"`
      event for any ability with a real cast time (Rebirth, Tranquility -
      Innervate/Swiftmend/Nature's Swiftness/Dark Rune are all instant and never
      generate one), and that begincast event carries no resolved target
      (`target: {"name":"Environment",...}`, same shape as the self-only-spell
      case the 2026-07-12 self-cast fix already handles) - so it was both
      double-counting the real cast AND getting miscounted as self via that same
      null-target fallback. Fixed by excluding `type == "begincast"` from the
      cooldown-guid match in `summarize_class_benchmarks.ps1`. Only affects
      Rebirth and Tranquility (the only two cast-time abilities in the tracked
      set) - Innervate/Swiftmend/NS/Dark Rune counts were never affected.
      Regenerated Druid's `benchmark_cooldowns.csv` to confirm.

## Blocking the "best version" report — do these first

- [x] **Build one real v2 boss page end-to-end.** Done for Danceswtrees / Hydross
      the Unstable (2026-07-07): `docs/danceswtrees/2026-07-07/healer_audit_hydross.html`,
      built entirely from real data (healing/casts events, consumables, real WCL
      percentile cross-matched by exact report/fight ID, real Top 100 benchmark
      comparison). `boss_page_template_druid.html`'s placeholder set held up
      against real data with no structural surprises — union-of-spell-lists,
      self/other cooldown targeting, boolean vs. real-% buff display all worked
      as documented. (CLAUDE.md open item #1)
- [ ] **Extend to the other 8 bosses for Danceswtrees's 2026-07-07 raid night.**
      Hydross and Leotheras the Blind are done (2/10). Leotheras's build surfaced
      a real bug (`begincast` double-counting, fixed - see above) and confirmed a
      second real, consistent finding across both kills so far: Danceswtrees's
      Lifebloom-over-Regrowth HoT-mix gap vs. the Top 100 average, and a
      below-average HPM on both. `docs/danceswtrees/2026-07-07/index.html` (the v2
      raid overview) already has explicit "not migrated" pending rows for the
      rest, each linking to its real v1 page in the meantime — see "New folder
      convention" below before touching any of these.
- [x] *Mostly resolved:* **Gear audit regression.** Confirmed the `combatantinfo`
      events pull (same mechanism as flask/food) works for getting real gear back
      — pulled it live for Danceswtrees/Hydross and built a real gear audit
      section in the v2 raid overview from it. Also discovered `parses/character`
      responses already include a real average item level in the
      `ilvlKeyOrPatch` field (verified: matched the combatantinfo-computed
      average, 120, exactly) — a future boss page's header `{{ITEM_LEVEL}}` may
      not need a fresh combatantinfo pull at all, just this field. Still open:
      the audit is scoped to ONE fight's snapshot — WORKFLOW.md's "confirm gear
      is identical across all kills before presenting one audit" rule hasn't
      been satisfied yet, since the other 9 kills have no v2 combatantinfo pull.
- [ ] **Two new real findings from that one gear snapshot, unresolved:** (1) a gem
      recount directly from the raw data gives 13 non-meta gems, not the 12 v1's
      original audit stated — a real discrepancy between v1's write-up and what
      the data actually shows, not yet reconciled either direction. (2) one gear
      slot shows no item equipped (generic empty-slot icon in the raw
      `combatantinfo` response) — real, but which slot it is couldn't be
      determined from the data alone this session.
- [x] **"Union of both spell lists" requirement — now fully verified, not just
      exercised.** The Top100-avg switch (below) surfaced 2 real benchmark-only
      guids (Regrowth 9857/9858, ~0.9%/0.6% of the Top 100 average) that
      Danceswtrees never cast — didn't show up at all under the old Top-10-only
      view. The Hydross page now genuinely shows both as real 0% rows per the
      union rule, the actual edge case this requirement exists for, not just the
      trivial case where both lists already matched.
- [x] *Reviewed, not live-tested:* **`pull_character_TEMPLATE.ps1` compatibility.**
      Read the full script this session — output field shapes (`sourceName`,
      `totalAmount`, `totalOverheal`, `events[]`, `flaskActive`/`foodActive`/
      `treeOfLifeUptimePct`) match what the Hydross page consumed with no
      adjustment needed. All Danceswtrees data used was from an existing pre-session
      pull, though — this confirms the format still lines up, not that a *fresh*
      run of the script still works end-to-end. A real live test pull is still
      worth doing at some point.

## Top100-avg methodology switch (2026-07-12)

- [x] **Switched every "Top 10 avg" aggregate to "Top 100 avg."** Was: spell
      composition, target coverage, cooldown/utility casts, and flask/food/Tree
      of Life stats were all computed over only the best 10 of the ~100 real
      parses pulled per boss, throwing away ~90 real data points for a noisier
      10-person average. Now: every one of those aggregates uses the full real
      sample (`SampleSize`/`SampleUsed` still reports the true count, not
      assumed to be exactly 100). `HPS_Top1` and `HPS_Median` were already
      whole-sample stats and didn't change. Updated: `summarize_class_benchmarks.ps1`
      (columns renamed `Top10*` → `Top100*` throughout both CSVs and code),
      `boss_page_template_druid.html` (all "Top 10" language → "Top 100"),
      WORKFLOW.md's benchmark-methodology descriptions, and the real Hydross
      page's numbers/findings fully recomputed against the new CSVs — not just
      relabeled. Regenerated all 4 Druid `benchmark_*.csv` files against real
      active data to confirm.
- [x] **Fixed: Nature's Swiftness's (and any similarly self-only spell's)
      self-cast % was wrong in the benchmark.** Root cause: WCL logs a
      self-only-castable spell's cast event with `target:
      {"name":"Environment","id":-1,...}` instead of a real actor, since there's
      no other-actor target to report - the pull scripts left `targetName` as
      `null` in this case, and `summarize_class_benchmarks.ps1`'s self-check
      (`sourceName -eq targetName`) silently counted every one of these as "not
      self." Fixed in three places: (1) `summarize_class_benchmarks.ps1` now
      also counts a null/empty `targetName` as self; (2) `pull_top100_druid.ps1`
      and (3) `pull_character_TEMPLATE.ps1` now annotate these events with the
      caster's own name instead of `null` at pull time, so future data doesn't
      need the same workaround. No bulk re-processing of already-pulled files
      needed - fix (1) alone makes both old (null) and new (self-name) data
      compute correctly. Regenerated Druid's `benchmark_cooldowns.csv` to
      confirm, and updated the Hydross page's coverage-note with the real
      corrected number.

## Known data gaps / report-copy caveats

- [x] *Deprioritized, not needed for now:* **Tranquility's guid is unobserved** —
      `$cooldownGuids["Tranquility"]` is an empty array, so `benchmark_cooldowns.csv`
      shows 0 casts/0% used for every boss regardless of reality. Originally risky
      because a report could read "0% of the Top 100 used Tranquility" as a real
      finding — but the 2026-07-12 conditional-display rule (Tranquility's row on a
      boss page only appears when the character's usage is a real deviation from
      Top100UsedPct) already neutralizes that risk: a permanently-0 benchmark number
      just means the row never gets shown as "notable," not that a wrong number gets
      surfaced. Revisit adding the real guid only if Tranquility usage actually needs
      to be tracked for some other reason later — not blocking anything right now.
- [x] **`resources`/`resources-gains` (HPM, mana-over-time) — resolved, and better
      than expected (2026-07-12).** The API endpoint itself is confirmed dead: 5
      real test calls (events + tables endpoints, `abilityid` 0/1/absent,
      with/without `sourceid`, against a known-good real fight) all failed —
      either the same `"No valid resource type specified."` error the original
      attempt hit, or (for `resources-gains` with no `abilityid`) a different,
      more fundamental `"Invalid command specified."` rejection suggesting that
      view may not even be recognized on this deployment. The documented
      `abilityid` param genuinely doesn't work against the real Fresh Classic
      API — a real spec/API mismatch, not a param-guessing problem.
      **But it turned out not to matter** — while chasing this, found that every
      `*_casts_events.json` file already pulled (character AND Top 100 data
      alike) carries a `classResources[0]` object per cast event with real mana
      data under misleadingly generic field names: `amount` = max mana pool
      (constant, e.g. 10175), `max` = that spell's real mana cost (verified
      against known real TBC costs — Lifebloom 220, Rejuvenation 415, Regrowth
      675, Healing Touch 935, etc — matched exactly), `type` = current mana at
      that moment (traced across a full real kill: smooth 10175→2781 decline
      with small regen bumps, not a "resource type ID" despite the name).
      **Built into the pipeline the same day**: `summarize_class_benchmarks.ps1`
      now computes HPM per parse (effective healing / total mana cost summed
      from `classResources[0].max`) and adds `HPM_Top1`/`HPM_Top100Avg`/
      `HPM_Median`/`HPM_SampleUsed` to `benchmark_summary.csv` — regenerated and
      verified real on Hydross (Top1=7.59, avg=median=5.82, full 100-sample
      used). `boss_page_template_druid.html`'s Cooldowns & Consumables stat grid
      grew a 5th stat for it (scoped `.stat-grid-5` CSS modifier so the
      Scorecard's own 4-stat grid is untouched). The real Hydross page now shows
      Danceswtrees's real HPM (3.45) — meaningfully below both the Top 100
      average and median, a genuine finding that reinforces the scorecard's
      overheal problem from a different angle (mana was spent, a lot of the
      healing it bought didn't count as effective). A real mana-over-time trace
      (using the `type` field) is still just decoded, not built into anything -
      no immediate use case for it yet. Updated WORKFLOW.md (gotcha #11 + the
      boss-page spec section), CLAUDE.md, and both pull scripts' header comments
      with the full story.
- [x] *Checked, not a bug:* `benchmark_buffs.csv` showing identical
      Flask%/Food% for some bosses (e.g. Morogrim 70/70, from the old Top-10-only
      view — worth a fresh look now that the aggregate is Top 100) is a genuine
      correlation among prepared raiders, not a code bug — spot-checked real
      `_consumables.json` files and confirmed flask/food are computed
      independently (found real divergent cases: flask-no-food, neither).
- [ ] **~0.5% of Top 100 parses (1 in ~200) have no `combatantinfo` snapshot** even
      within the 2-minute backward buffer, likely a late-joining player. Reported
      as a failure for that player's consumables specifically, never treated as
      "no flask" — if the specific character being reported on hits this, that
      boss's flask/food section has a real, honest gap. Don't paper over it.
- [ ] **The ≥2,900-event warning is a heuristic, not a guaranteed-complete check.**
      No confirmed real truncation on `/report/events/` yet, but nothing rules it
      out on an unusually long fight (Vashj/Kael'thas run long). Worth a second
      look if a report's numbers look implausibly low for a specific long kill.

## Real bugs found this session, not yet fixed

- [ ] **A parse that drops out of the Top 100 and later re-enters is mishandled.**
      Confirmed by re-reading `pull_top100_druid.ps1`'s diff logic: it only checks
      parses with `status == "active"` to decide what's new, so a re-appearing
      archived parse gets treated as brand-new — wastefully re-fetched from the
      API even though identical data already sits in `archived\{Boss}\`, its
      manifest entry gets overwritten (losing the original `firstSeenAt`), and the
      stale archived copy is never cleaned up or reconciled. Ends up with the same
      parse's files in both `active\` and `archived\` at once. Not hit yet in
      testing (nothing has re-entered across the two live runs so far), but real
      and findable the moment it happens.
- [ ] **`manifest.json` has no pruning, grows indefinitely.** Already ~1.3MB at
      1,000 active parses; archived entries kept forever by design. Not urgent,
      just a scaling note for whatever eventually reads this file often.

## New folder convention — read before building the remaining 9 boss pages

Established this session, real and in use now: v1 and v2 output for the same
healer+raid-night live side by side, never overwriting each other.
```
docs/{healer}/{date}-v1/    <- original v1 pages, frozen, git-tracked reference
docs/{healer}/{date}/       <- new v2 pages, built incrementally as each boss gets done
```
`docs/danceswtrees/index.html` links to both explicitly ("SSC / TK - V1" / "SSC / TK
- V2" rows). **Never write directly into a `-v1` folder** — this session already
made that mistake once (overwrote the live v1 Hydross page by accident before this
convention existed) and had to restore it from git history. Always create/edit only
under the plain `{date}` folder for new v2 work.

## Explicitly out of scope for now

- Paladin/Priest/Shaman are still v1 (healing TABLE, truncation-prone) AND the old
  date-stamped-folder convention. Not being worked on until Druid v2 is proven out
  end-to-end. `summarize_class_benchmarks.ps1 -DateFolder {date}` now fails loudly
  instead of silently writing empty CSVs if pointed at v1 data it can't parse — see
  WORKFLOW.md gotcha #25.
