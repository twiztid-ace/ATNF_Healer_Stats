# Druid v2 pipeline — TODO / known issues

Living tracker for bugs and open work on the enhanced (v2, events-based) Druid
pipeline specifically. Not a duplicate of WORKFLOW.md's gotcha list — cross-references
it where relevant, but this file is for *tracking status* (open/in-progress/done),
WORKFLOW.md stays the deep explanation of *why*. Update this as items get fixed or
new ones get found — don't let it go stale.

## Blocking the "best version" report — do these first

- [ ] **Build one real v2 boss page end-to-end**, at least one full raid night,
      using real Druid v2 data. Nothing has actually exercised
      `boss_page_template_druid.html` against this shape of data yet — this is the
      fastest way to surface whichever of the items below actually bites first.
      (CLAUDE.md open item #1)
- [ ] **Gear audit regression** — healing *events* carry no `gear` field (the old
      healing *table* did, which is what the raid overview's gear audit reads).
      Needs a `combatantinfo` events pull (same mechanism already used for
      flask/food) before any raid overview page can show gear. Will hit on the
      very first v2 raid overview built.
- [ ] **Verify "union of both spell lists" is actually implemented.** WORKFLOW.md
      documents this as a real bug caught once before (benchmark-only spells the
      character never cast get silently hidden from the comparison if you don't
      union both lists) — fixed conceptually in the design, never exercised
      against real Druid v2 data since no v2 boss page exists yet.
- [ ] **Re-verify `pull_character_TEMPLATE.ps1`'s output still lines up** with the
      current `benchmark_*.csv` column names/shape. Untouched this session while
      everything else changed — do one real test pull before trusting the
      character-side of the pipeline is still in sync with the benchmark side.

## Known data gaps / report-copy caveats

- [ ] **Tranquility's guid is unobserved** — `$cooldownGuids["Tranquility"]` is an
      empty array, so `benchmark_cooldowns.csv` shows 0 casts/0% used for every
      boss regardless of reality. Risk isn't the missing number, it's a report
      reading "0% of Top 10 used Tranquility" as a real finding. Any report copy
      touching cooldowns must omit Tranquility or caveat it explicitly until a
      real cast is observed and the guid gets added.
- [ ] **`resources`/`resources-gains` (HPM, mana-over-time) still untested** with
      the correct `abilityid` param (the earlier `resourcetype` guess was
      confirmed wrong). Not blocking, just unclaimed upside.
- [x] *Checked, not a bug:* `benchmark_buffs.csv` showing identical
      Flask%/Food% for some bosses (e.g. Morogrim 70/70) is a genuine correlation
      among prepared Top 10 raiders, not a code bug — spot-checked real
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

## Explicitly out of scope for now

- Paladin/Priest/Shaman are still v1 (healing TABLE, truncation-prone) AND the old
  date-stamped-folder convention. Not being worked on until Druid v2 is proven out
  end-to-end. `summarize_class_benchmarks.ps1 -DateFolder {date}` now fails loudly
  instead of silently writing empty CSVs if pointed at v1 data it can't parse — see
  WORKFLOW.md gotcha #25.
