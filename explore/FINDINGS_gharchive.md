# Archived findings — GH Archive (dropped 2026-08-21)

GH Archive was selected, profiled end to end, and then dropped. The dataset
selection criteria and the reason for dropping it are in `CLAUDE.md`.

These numbers are kept because the *method* that produced them transfers to
whatever dataset comes next, and because the reasoning is worth re-reading
before profiling a new candidate. Nothing here is live guidance.

Reproduce with `duckdb -f explore/01_profile_hour.sql` (needs a downloaded hour
in `data/raw/`).

---

## Profiling findings (from 2026-08-18-15.json.gz, 41,127 events)

Run `duckdb -f explore/01_profile_hour.sql` to reproduce.

**Volume and keys**
- 41,127 events in the hour, all IDs distinct, span exactly 15:00:00–15:59:59.
- Zero nulls on `repo.id` and `actor.id`. 13,424 distinct repos, 11,861 actors.
- No repo id carried two names within the hour — but a single hour proves
  nothing about rename stability. Re-test across months once history is loaded.

**PushEvent dominates and carries almost nothing**
- 95.3% of events (39,198).
- Payload keys are only `repository_id, push_id, ref, head, before`.
- No `commits` array, no `size`. Commit messages are NOT available in this feed.
  This killed the original plan to embed commit messages.

**Genuine schema drift — the reason this dataset was chosen**
- `IssuesEvent` appears in three shapes: `[action, issue]` (56),
  `[action, issue, label, labels]` (55), `[action, issue, assignee, assignees]` (8).
- `PullRequestEvent` likewise: `[action, number, pull_request]` (227),
  `+ label, labels` (71), `+ assignee, assignees` (8).
- Optional keys materialize only when the action involves them. A struct-based
  flatten would silently drop columns depending on which rows got sampled.
  **Silver must treat payload keys as optional and null-safe.**

**The drift that matters is one level down**
- Queries 1-6 stop at `json_keys(payload)`. That is depth 1, and it is the less
  interesting level. The columns silver has to extract live inside
  `payload.issue` and `payload.pull_request`. Queries 7-8 profile those.
- `payload.issue` is **complete** — ~30 keys including `body`, `title`, `state`,
  `created_at`, `closed_at`, `labels`, `assignees`, `reactions`.
- It also drifts harder than depth 1 does: four distinct shapes each for
  `IssuesEvent` (63/47/6/3) and `IssueCommentEvent` (57/52/31/13) inside a
  single hour. `issue_field_values`, `sub_issues_summary`,
  `issue_dependencies_summary`, `parent_issue_url` and `pinned_comment` come and
  go. These track optional product features rather than the action type, which
  makes them both better drift evidence than the depth-1 variation above and
  much harder to predict from the event type alone.
- `payload.pull_request` is the opposite — **truncated**. One shape, five keys,
  across all 306 events: `[url, id, number, head, base]`. No `title`, `body`,
  `state`, `merged`, `merged_at` or `created_at`.

**Text is thinner than expected**
- Only ~344 text-bearing events per hour (~690 KB).
- `IssueCommentEvent` 153 (avg 2671 chars), `IssuesEvent` 117/119 (avg 2220),
  `PullRequestReviewCommentEvent` 72 (avg 1184), `CommitCommentEvent` 2.
- `PullRequestEvent`: 306 events, **0 with body text**. RESOLVED (query 8) —
  the `body` key is *absent*, not present-and-null, and so is most of the rest
  of the object. Silver must synthesize the column rather than select it.
- Issue and comment bodies, by contrast, are already in the feed. Hydration is
  therefore PR-only: ~306 requests per archive hour, not ~344. At the
  authenticated rate limit of 5,000 requests/hour that is roughly 16 archive
  hours hydrated per wall-clock hour — the real ceiling on backfill speed, and
  a tighter constraint than the dollar budget.


---

### Fact grain decision

Given the 95/5 split, a single wide fact table would be mostly null. Use a base
fact plus type-specific facts:

- `fact_event` — one row per event, all types. Conformed columns only:
  `event_id, repo_key, actor_key, date_key, event_type, created_at`.
- `fact_pull_request` — one row per PR event. `action` and `pr_number` come
  straight from the feed. State and review-latency measures do **not**: the
  truncated `pull_request` object carries no state and no timestamps. Two ways
  to source them, and this has to be settled before gold is built:
  1. **Derive from the event sequence** — `action='opened'` at T1 against
     `action='closed'` at T2, joined on `pull_request.id`, as an intermediate
     model. Costs no API calls, but only works where loaded history is
     contiguous across both events. That makes history depth a modelling
     decision, not just a cost one.
  2. **Hydrate from the REST API** — which promotes hydration from "restores
     text" to load-bearing for the gold layer.
- `fact_issue` — one row per issue event: `action`, `issue_number`, labels.

