# CLAUDE.md

Context for AI assistants working in this repo. Read this first.

## What this project is

An end-to-end data platform on a recurring event stream, combining a
dimensional warehouse with a vector index so an AI agent can answer questions
needing both metrics and text.

The source is the **CFPB Consumer Complaint Database** - every complaint
Americans file about a bank, lender or credit agency, and what the company did
about it.

It is a portfolio project. The audience is hiring managers for
analytics-engineering and data-engineering-manager roles. Decisions should
favor what is legible and defensible in an interview over what is clever.

## Owner context

- Works on Windows, PowerShell. Paths are `C:\projects\github-activity-platform`.
- Limited hours per week. Prefers steady shippable increments over big rewrites.
- Wants beginner-level explanation of *why* a step exists, not just the command.
  Explain the concept behind the step. Do not be condescending.
- Prefers direct feedback over diplomatic softening. Say when something is a bad idea.
- For multi-file changes: lead with a grouped overview — what each cluster of
  changes does and why, what is done vs pending, which edits must ship together —
  before the detailed diffs.

## The question the agent answers (settled 2026-08-25)

This was never written down, and its absence is what stalled the first attempt.
The project described the *shape* of the answer ("metrics and text together")
but never one actual question - which left nothing to test a dataset against.

Fix the order permanently: **question first, then dataset.**

The system has two halves, each useless at the other's job. The warehouse
counts, times, compares and trends; it cannot say what anyone wrote. The vector
index finds what people wrote; it cannot count. So any question one half can
answer alone demonstrates nothing.

The only shape needing both is: **a number moved - why?**

"It moved" is arithmetic. "Why" is language. And answering *why* means
retrieving text from exactly the entities and exactly the window the metric
flagged - which is what the shared join key buys, and what a bolt-on vector
store cannot do.

Target demo:
1. Warehouse computes a measure per entity per week and locates the jump.
2. That entity list and date range become a filter on the vector index.
3. Retrieve only text from those entities, in that window.
4. Answer citing both halves.

A candidate dataset must support at least one such question. If it cannot, its
size and cleanliness are irrelevant.

### The concrete question

> **"Complaints about this company's mortgages tripled in July, and the share
> ending in money back fell. Why?"**

CFPB was chosen because it answers this better than any candidate evaluated:
the narrative field *is* an explanation of the outcome being measured. In every
rejected candidate the text was either marketing copy, short labels, or about
something other than the metric.

Build order follows from the question, not the other way round:
`company x product x week` measures -> spike detection -> narrative retrieval
filtered to that company, product and window -> answer citing both.

## Dataset decision (settled 2026-08-25) - CFPB Consumer Complaints

**Source:** `https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/`
Free, public, no API key, no quota. Bulk CSV export exists for backfill.

**Verified profile** (measured 2026-08-25, do not re-derive):

| | |
|---|---|
| Total complaints | 17,303,755 |
| With a narrative | 3,842,857 (22.2%) |
| Newest record | 2026-08-24, i.e. one day behind - **updates daily** |
| Arrival rate | 91,419 over 7 days, ~13,000/day, ~2,900 narratives/day |
| Narrative length | median 1,174 chars, mean 1,525, p90 3,111, max 11,598 |
| Routing latency | received -> sent to company: median 0.01 days, p90 0.20, max 4.7 |

Outcome mix, which is the funnel's terminal step:

| company_response | count |
|---|---|
| Closed with explanation | 10,630,138 |
| Closed with non-monetary relief | 5,797,520 |
| In progress | 586,670 |
| Closed with monetary relief | 216,268 |
| Untimely response | 32,356 |

`timely`: 17,196,704 yes / 107,051 no. In a recent 600-row sample **17.8% ended
in some form of relief** - that ratio is the headline funnel metric, and it
varies by company and product.

**Volume skew:** credit reporting is 11,780,564 of 17.3M (68%). Same shape as
the GH Archive push dominance, so the fact grain principle below applies.

### Access path (verified 2026-08-26)

There are two endpoints and picking the wrong one costs a week.

- **JSON search** caps its `frm` offset at **10,000**. The date filter accepts
  **whole days only** (`YYYY-MM-DD`; timestamps are rejected). Since ~12,000-
  18,000 complaints arrive per day, a one-day window is already past the cap
  and cannot be sliced finer by date. Paging the feed this way does not work.
- **CSV export** (`format=csv`) has **no row cap**. A single request for
  2026-08-18..20 returned 55,052 rows, matching the count endpoint exactly.

So: **CSV export for all bulk and incremental pulls; JSON only for counts and
aggregations**, where its facets are genuinely useful and the cap is irrelevant.
Reaching for adaptive window-splitting means solving a problem the other
endpoint does not have.

CSV column names are the human-readable labels - `Date received`,
`Consumer complaint narrative`, `Timely response?` - not the snake_case names
the JSON endpoint returns. Bronze normalizes those names only because Delta
rejects some characters; values stay untouched.

### The two clocks - the constraint that shapes the whole design

Measured 2026-08-26 by sampling complaints by month of arrival and asking what
is visible today:

| received | still "In progress" | has a narrative |
|---|---|---|
| this month | 68.7% | 0.0% |
| 1 month ago | 38.2% | 0.5% |
| 2 months ago | 3.1% | 2.4% |
| 4 months ago | 0.0% | 3.4% |
| 9 months ago | 0.0% | 15.7% |
| 12 months ago | 0.0% | 22.0% |

**Outcomes settle in ~2 months. Narratives publish at ~9-12 months.**

Three consequences, none optional:

1. **Today's data cannot answer the question.** The metric moves at the live
   edge; the narratives explaining it are not published for the better part of
   a year. The analytical window trails ingestion by ~12 months. Any demo must
   run against matured history, not yesterday.
2. **Bronze cannot be append-only-and-forget.** A narrative attaches to a
   complaint that already landed months earlier. Re-pulling matured windows is
   a first-class pipeline concern, not a one-off backfill.
3. **The daily job still pays off long before then** - it captures the
   `In progress` -> resolved transition, which is the only source of resolution
   latency, and that settles within ~2 months.

A recent 3-day sample was also **96% credit reporting** (vs 68% across all
history), so recent-window aggregates say almost nothing about other products.

### Where the mess actually is - NOT nesting

Records come back **flat**. This is a real departure from the GH Archive plan:
there are no nested payloads to flatten, so depth-2 profiling matters less here.
Silver earns its keep differently:

- **Optional fields.** In a 600-row sample: `tags` non-null 147/600 (24.5%),
  `sub_issue` 559/600, `state` 594/600, `zip_code` 595/600.
- **Category drift over time.** The product taxonomy was renamed mid-history -
  "Credit reporting, credit repair services, or other personal consumer
  reports" and "Credit reporting or other personal consumer reports" are both
  live in the data and must be reconciled.
- **Pre-redacted text.** Narratives arrive with personal details replaced by
  `XXXX` and `XX/XX/year>`. Needs cleaning before embedding, or the redaction
  tokens pollute the vectors.
- **Literal `"None"` strings.** The CSV export writes `None` as text where a
  value is empty - it is not null and not blank. In a 55,052-row sample: `tags`
  98.6% `"None"`, `company_public_response` 84.4%, `sub_issue` 0.5%. Left alone
  it passes every null check and becomes a valid category.
- **Company name inconsistency** - first check came back clean: zero
  near-duplicate company names in a 55,052-row sample. Inconclusive, because
  that sample was 96% credit reporting and so covers few distinct companies.
  Re-test across full history before trusting it.

### Still to profile

- Company name normalization across full history, not a recent sample. This
  is the join key between the warehouse and the vector index, so variants split
  a company's metrics and make filtered retrieval miss its own narratives.
- How far back narratives keep accruing - the table above stops at 12 months.
  Does coverage plateau at 22%, or keep climbing?
- The `In progress` -> resolved transition. **There is no company-response date
  field**, so response latency only exists if the pipeline snapshots daily and
  detects transitions itself. That is a Type 2 slowly-changing dimension and it
  only works if the scheduled job genuinely runs - which is the orchestration
  experience this project exists to demonstrate.

### Known limitation to state out loud, not hide

Narratives are **opt-in**, so the 22.2% that have one are self-selected and may
not represent all complainants. Any narrative-derived finding carries that
caveat. Naming it is a strength; discovering it in an interview is not.

### The bar it was chosen against

Kept because it records why, and because reopening this again is expensive.

1. **Arrives on a recurring schedule.** Daily, verified. This disqualified the
   GA4 ecommerce sample and the Yelp Open Dataset.
2. **Contains real free text.** Prose someone wrote, not short labels. This
   disqualified GA4, eBay and most tabular sets.
3. **Supports a funnel.** submitted -> routed -> answered -> relief or not,
   with measurable drop-off at each step.
4. **Supports "a number moved - why?"** The narrative explains the outcome the
   metric measures. This is what eBay and Amazon-review data failed: listings
   and marketing copy cannot explain a metric they predate.

Preferences also met: explicable in one sentence, structurally messy, free.

### Rejected candidates and why

| candidate | fatal flaw |
|---|---|
| GH Archive | text thin, PR bodies absent, questions too niche; dropped after full profiling |
| GA4 ecommerce sample | static one-time load; no prose |
| Yelp Open Dataset | static download; no real funnel (check-ins carry no user id) |
| eBay API | text is keyword-stuffed titles and templated listings; cannot explain a metric |
| Descripio / Amazon reviews | paid scraper, grey-area terms, no funnel |
| Stack Exchange | strong text and funnel, but a tech domain with GitHub's legibility problem |
| City 311 | strong funnel and cadence, but complaint text mostly unpublished |
| NHTSA vehicle safety | genuine runner-up: complaint -> investigation -> recall, real prose. Fan-out ingestion by make/model/year is the only reason it lost |
| ClinicalTrials.gov | genuine runner-up: deep nesting, a literal `whyStopped` field. Funnel moves over months to years, so weekly movement is muted |

## Profiling method - run this against any candidate

The GH Archive numbers are archived; these techniques are why that work was not
wasted.

- **Profile nested structures at depth 2, not depth 1.** Listing top-level keys
  makes a payload look simpler than it is. On GH Archive, depth 1 showed three
  shapes per type; depth 2 showed four *more*, and revealed that the entire pull
  request object was truncated to five keys. Open the nested objects before
  designing any table against them.
- **Distinguish "key absent" from "key present but null."** These need different
  handling in silver: absent means the column must be synthesized, null means it
  can be selected normally. Counting the key directly settles it; a
  null-returning string extractor cannot tell them apart.
- **Verify a claim before building on it.** The plan to embed commit messages
  died because nobody had checked whether commit messages were in the feed.

### The coverage curve - this transfers directly to funnels

Any measure derived by matching a start event to a later end event is
*left-censored*: an entity that started before the loaded window is visible
ending but not starting, so it cannot be measured. History therefore splits into
a **running start**, which holds the beginnings and cannot be reported on, and a
**reporting window**, which can.

This is not GitHub-specific. On CFPB it applies to the `In progress` ->
resolved transition: a complaint already in progress when snapshotting begins is
seen resolving but not arriving, so its resolution time cannot be measured.
History depth is therefore a modelling decision, not only a cost one.

Do not guess the running start. Measure it: take the end events with the deepest
lookback available, vary the lookback, and stop where the curve flattens.
`explore/02_pr_coverage_curve.sql` implements this and is worth reusing as a
template. Its honest-measurement rule matters: coverage at lookback *k* may only
be measured on rows that actually have *k* days of history behind them.

## Architecture

```
recurring source ─┐
                  ├──► BRONZE   raw records, schema-on-read, nothing dropped
enrichment API ───┘   (the second source is optional - it exists when
                       the stream carries less than the full record)
                       │
                       ▼
                    SILVER      flattened + typed, deduplicated, one row per
                       │        event, payload normalized per type, null-safe.
                       │        No business logic.
                       ▼
                 INTERMEDIATE   joins and pre-aggregations. Not exposed.
                       │
                       ▼
                     GOLD       base fact + type-specific facts + conformed
                       │        dimensions (see fact grain principle below)
                       │
                       ├──────► semantic layer (dbt MetricFlow)
                       │
                       └──────► vector index (free text, tagged with the
                                same keys → joins back to gold)
```

### Fact grain principle

When one record type dominates volume, a single wide fact table is mostly null.
Use a base fact carrying only conformed columns, plus type-specific facts for
attributes that apply to some types only.

On GH Archive that meant `fact_event` plus `fact_pull_request` and `fact_issue`,
because pushes were 95.3% of volume and carried nothing. The specific tables are
archived in `explore/FINDINGS_gharchive.md`; the principle applies to whatever
comes next.

## Repo layout (Databricks Asset Bundle standard)

```
databricks.yml           bundle root - dev and prod targets
resources/               job + cluster config as versioned YAML
src/ingestion/           CFPB client, sampling, landing
src/vector/              chunking + index build
dbt/models/staging/      silver - renaming, typing, null-safety
dbt/models/intermediate/ joins, pre-aggregations, transition detection
dbt/models/marts/        gold - facts and dimensions
dbt/macros/              source quirks encoded once, with the reason
explore/                 DuckDB profiling
tests/                   unittest
```

The repo is `complaint-analytics-platform`; the previous one is renamed
`complaint-analytics-platform-archive` and holds the GH Archive history.

## Stack

| Layer | Tool |
|---|---|
| Exploration | DuckDB (local) |
| Storage / compute | Databricks — Delta Lake, Unity Catalog |
| Ingestion | Auto Loader |
| Transformation | dbt (staging → intermediate → marts) |
| Retrieval | Mosaic AI Vector Search (synced index, so embeddings self-refresh) |
| Orchestration | Databricks Jobs / Asset Bundles |

Snowflake is a planned second implementation after Databricks, for the second
resume keyword. Not now.

## Working conventions

Code lives in git. The cluster is disposable compute pointed at that code. If
the workspace vanished, the repo should rebuild it. Concretely:

- Develop locally in the IDE, not in notebooks. Notebook-only work is the tell
  that someone has not worked on a team.
- Databricks Connect runs Spark on the remote cluster from local code.
- Asset Bundles version job config as YAML. No clicking jobs together in the UI.
- Two Unity Catalog catalogs, `dev` and `prod`, same schema names in each.
- Feature branch → PR → merge. Review your own PRs; the diff catches things.
- CI runs `dbt build` against dev on the PR.

Deliberate sequencing — do NOT build all of this before there is data:
1. Repo + scaffold ✅
2. Unity Catalog dev/prod
3. Databricks Connect working end to end (one script: read file → write Delta)
4. Bronze + silver as plain scripts
5. Asset Bundles once there is something worth scheduling
6. CI once there are dbt tests worth running

## Cost guardrails

Budget is modest. Set cluster auto-terminate to ~10 minutes. Expect roughly
$5–15/month on Databricks for a filtered slice. Restrict history and repo count
before ingesting broadly.

## Status

- [x] Repo scaffolded - README, .gitignore, profiling queries
- [x] Git identity configured, scaffold committed and pushed to origin/main
- [x] GH Archive profiled end to end, then dropped
- [x] Reusable profiling method and coverage-curve technique extracted
- [x] Question defined - see The question the agent answers
- [x] **Dataset chosen: CFPB Consumer Complaints**, profiled at survey depth
- [x] Access path verified: CSV export, not JSON paging
- [x] Publication lag measured - the two clocks above
- [ ] Repo scaffold rebuilt by hand (in progress - see below)
- [ ] Full profile: company name normalization across full history
- [ ] Databricks workspace + Unity Catalog dev/prod
- [ ] Databricks Connect working end to end
- [ ] Bronze landing - daily incremental pull, plus CSV backfill
- [ ] Silver - category reconciliation, redaction cleanup, daily snapshot for
      state transitions
- [ ] Gold star schema
- [ ] Vector index over narratives, keyed to company + product + date
- [ ] Agent

## Where to pick up

The first unchecked box in Status is the next thing to do. That checklist is the
single source of truth for sequencing — do not add a second "next steps" section
here or in the README, because the two will drift apart within a session.

## Guardrails for the assistant

- **Teach, do not do.** He rebuilds the code himself; explain the concept, show
  the shape, let him type it. Reviewing and critiquing his version is welcome;
  substituting for it is not. Recorded facts (this file, archived findings) are
  the exception - maintain those directly. Running something to establish a
  fact is fine; hand the doing back afterwards.
- **The dataset is settled: CFPB Consumer Complaints, 2026-08-25.** Three
  candidates were evaluated and rejected before it, and the criteria it was
  chosen against are recorded above. Reopening this a third time is expensive
  and has never yet been the actual problem. Augmenting beats switching.
- **A vague "this dataset feels wrong" is usually a missing question, not a bad
  dataset.** That is what happened on 2026-08-21: the doubt arrived immediately
  after discovering that no question had ever been written down. Check the
  question is defined before entertaining a switch - swapping data does not fill
  that hole, and it discards the profiling work.
- **Do not re-derive what is already archived.** `explore/FINDINGS_gharchive.md`
  holds the GH Archive numbers. It is history, not live guidance.
- The differentiator is the vector index joined back to the warehouse on a
  shared key. Plenty of people bolt on a vector store and never join it to the
  warehouse. Everything else is supporting cast - protect that piece.
- Scope creep across all six stack layers before finishing any one of them is
  the main failure mode here. Each stage should be demoable on its own.
