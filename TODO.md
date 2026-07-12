# Druid v2 pipeline — TODO / known issues

Living tracker for bugs and open work on the enhanced (v2, events-based) Druid
pipeline specifically. Not a duplicate of WORKFLOW.md's gotcha list — cross-references
it where relevant, but this file is for *tracking status* (open/in-progress/done),
WORKFLOW.md stays the deep explanation of *why*. Update this as items get fixed or
new ones get found — don't let it go stale.

## Blocking the "best version" report — do these first

- [x] **Build one real v2 boss page end-to-end.** Done for Danceswtrees / Hydross
      the Unstable (2026-07-07): `docs/danceswtrees/2026-07-07/healer_audit_hydross.html`,
      built entirely from real data (healing/casts events, consumables, real WCL
      percentile cross-matched by exact report/fight ID, real Top 10 benchmark
      comparison). `boss_page_template_druid.html`'s placeholder set held up
      against real data with no structural surprises — union-of-spell-lists,
      self/other cooldown targeting, boolean vs. real-% buff display all worked
      as documented. (CLAUDE.md open item #1)
- [ ] **Extend to the other 9 bosses for Danceswtrees's 2026-07-07 raid night.**
      Only Hydross is done. `docs/danceswtrees/2026-07-07/index.html` (the v2 raid
      overview) already has explicit "not migrated" pending rows for the rest,
      each linking to its real v1 page in the meantime — see "New folder
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
- [x] *Partially verified:* **"Union of both spell lists" requirement.** Exercised
      against real data on the Hydross page — mechanism works. Caveat: Danceswtrees's
      6 cast spells happened to exactly match the benchmark's 6 tracked spells, so
      this didn't actually test the "benchmark-only spell never cast, must still
      show as 0%" edge case. Still worth watching for on a future boss/character
      where the lists genuinely diverge.
- [x] *Reviewed, not live-tested:* **`pull_character_TEMPLATE.ps1` compatibility.**
      Read the full script this session — output field shapes (`sourceName`,
      `totalAmount`, `totalOverheal`, `events[]`, `flaskActive`/`foodActive`/
      `treeOfLifeUptimePct`) match what the Hydross page consumed with no
      adjustment needed. All Danceswtrees data used was from an existing pre-session
      pull, though — this confirms the format still lines up, not that a *fresh*
      run of the script still works end-to-end. A real live test pull is still
      worth doing at some point.

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
