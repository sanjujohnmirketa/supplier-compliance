# Synthetic supplier test data

Eight suppliers spanning the risk/industry range, with the **actual checklist the
engine generates** for each (run live against `/scope`, 2026-06-15). Use these to
test the New Supplier → Generate Checklist flow and confirm the UI matches.

> Note: tiers and domains are driven by **country + industry + engagement + spend**.
> Change any of them and the checklist should regenerate. Industries the policy
> corpus doesn't cover correctly return "no industry-specific policy matched —
> general baseline only" (this is the engine being honest, not a bug).

| # | Supplier | Country | Industry | Engagement | Spend | Tier | Generated checklist |
|---|----------|---------|----------|-----------|-------|------|---------------------|
| 1 | Meridian Auto Components Ltd | Germany | Automotive | Direct Material - Production (Tier 1) | 8,200,000 | Medium | SDS+REACH/RoHS · Conflict Minerals (+ KYC, SAQ baseline) |
| 2 | Kongo Cobalt Mining SARL | DRC | Chemicals | Raw Materials / Commodities | 15,000,000 | High | SDS+REACH/RoHS · Conflict Minerals (+ baseline) |
| 3 | Helix Pharma Actives Pvt | India | Pharmaceutical | Direct Material - Production (Tier 1) | 6,400,000 | Medium | Baseline only — no pharma policy in corpus |
| 4 | SkyForge Aerospace Forgings | USA | Aerospace & Defense | Capital Equipment / Tooling | 11,000,000 | High | Baseline only — no aerospace policy in corpus |
| 5 | CloudSoft Advisory LLC | USA | Electronics / Semiconductors | Services / Consulting | 180,000 | Low | Baseline only |
| 6 | Andes Artisan Goods | Peru | Other | Indirect / Non-production (MRO) | 45,000 | Medium | Baseline only |
| 7 | Nordic Freight Partners | Sweden | Logistics & Distribution | Logistics / Distribution | 900,000 | Low | Baseline only |
| 8 | ByteSecure Data Centers | Ireland | Energy / Utilities | Services / Consulting | 2,300,000 | Medium | Baseline only |

## Suggested test cases for the "checklist updates on change" fix
- Take #5 (CloudSoft, Low) → change **spend to 9,000,000** → tier should rise.
- Take #1 (Meridian, Automotive) → change **industry to "Other"** → domains should
  drop to baseline + show the no-policy-match note.
- Generate a checklist, then change **engagement type** → a "may be out of date —
  Regenerate" banner should appear.

## Corpus-coverage gaps surfaced by this test
The corpus currently grounds: automotive / conflict-minerals / chemicals(material) /
finance / cyber / quality / general. It has **no** dedicated policy for: pharmaceutical,
aerospace & defense, logistics, energy/utilities. Those return baseline-only with a
note. Add policy files for them if richer checklists are wanted there.
