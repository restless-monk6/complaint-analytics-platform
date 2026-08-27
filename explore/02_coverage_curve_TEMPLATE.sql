-- Measure how much running start the open/close matching actually needs.
-- Usage:  duckdb -f explore/02_pr_coverage_curve.sql
-- Requires: python ingestion/fetch_pr_issue_history.py 2026-04-21 2026-08-20
--
-- The question this answers
-- -------------------------
-- fact_pull_request needs review latency, but the GH Archive pull_request
-- object carries no timestamps (see CLAUDE.md). Latency therefore has to be
-- derived by matching an 'opened' event to a later 'closed'/'merged' event.
--
-- That only works when the opening is inside the loaded history. A pull
-- request opened before the window starts is visible closing but not opening,
-- so it cannot be measured. The earliest part of any window is unusable for
-- this reason -- it exists to hold openings, not to be reported on.
--
-- So the real design question is not "how many days" but "how many days of
-- running start before the reporting window", and the answer is wherever the
-- curve below stops climbing.
--
-- Honest-measurement rule
-- -----------------------
-- Coverage at lookback k can only be measured on closes that actually have k
-- days of history behind them. The sample is therefore the LAST 7 DAYS of the
-- window -- the closes with the deepest lookback available -- and k is capped
-- so even the earliest close in that sample has k days behind it.

CREATE OR REPLACE VIEW hist AS SELECT * FROM 'data/history/*.parquet';


-- 1. What was actually loaded. Read this first: a gap in the archive removes
--    openings and makes every coverage number below read artificially low.
SELECT
    count(*)                                          AS rows_loaded,
    count(DISTINCT created_at::DATE)                  AS days_present,
    min(created_at)::DATE                             AS window_start,
    max(created_at)::DATE                             AS window_end,
    date_diff('day', min(created_at), max(created_at)) AS window_days
FROM hist;


-- The close events being measured, and the earliest opening of each subject.
-- Earliest, not latest: a pull request opened 100 days ago and reopened
-- yesterday still needs the 100-day-old record to compute true lifetime, so
-- anchoring on the original opening is the conservative choice.
CREATE OR REPLACE TEMP TABLE pr_closes AS
SELECT subject_id, created_at AS closed_at, action
FROM hist
WHERE event_type = 'PullRequestEvent'
  AND action IN ('closed', 'merged')
  AND created_at >= (SELECT max(created_at) - INTERVAL 7 DAY FROM hist);

CREATE OR REPLACE TEMP TABLE pr_opens AS
SELECT subject_id, min(created_at) AS opened_at
FROM hist
WHERE event_type = 'PullRequestEvent' AND action = 'opened'
GROUP BY subject_id;

CREATE OR REPLACE TEMP TABLE pr_matched AS
SELECT
    c.subject_id,
    c.closed_at,
    c.action,
    o.opened_at,
    epoch(c.closed_at - o.opened_at) / 86400.0 AS age_days
FROM pr_closes c
LEFT JOIN pr_opens o
  ON o.subject_id = c.subject_id
 AND o.opened_at  < c.closed_at;


-- 2. THE COVERAGE CURVE. This is the output that decides the number.
--    max_lookback is capped at the history available behind the earliest close
--    in the sample, so no row is credited with a lookback it never had.
WITH cap AS (
    SELECT floor(epoch(
        (SELECT min(closed_at) FROM pr_matched) - (SELECT min(created_at) FROM hist)
    ) / 86400.0) AS max_k
)
SELECT
    k                                                              AS lookback_days,
    count(*)                                                       AS closes_in_sample,
    count(*) FILTER (WHERE age_days IS NOT NULL AND age_days <= k) AS measurable,
    round(100.0 * count(*) FILTER (WHERE age_days IS NOT NULL AND age_days <= k)
          / nullif(count(*), 0), 1)                                AS pct_measurable
FROM pr_matched
CROSS JOIN (SELECT unnest([1,2,3,5,7,10,14,21,30,45,60,75,90,105]) AS k) ks
CROSS JOIN cap
WHERE k <= cap.max_k
GROUP BY k
ORDER BY k;


-- 3. Where the unmeasurable ones go. 'no_open_in_window' means the opening
--    predates the whole 4 months -- the true long tail, and the population
--    that no amount of realistic history will recover.
SELECT
    count(*)                                        AS closes_in_sample,
    count(*) FILTER (WHERE age_days IS NOT NULL)    AS open_found,
    count(*) FILTER (WHERE age_days IS NULL)        AS no_open_in_window,
    round(100.0 * count(*) FILTER (WHERE age_days IS NULL)
          / nullif(count(*), 0), 1)                 AS pct_unrecoverable
FROM pr_matched;


-- 4. The latency distribution itself, for the pull requests that did match.
--    This is the measure fact_pull_request will expose, so its shape matters:
--    a long right tail means the mean is useless and the median is the metric.
SELECT
    action,
    count(*)                                        AS n,
    round(quantile_cont(age_days, 0.50), 2)         AS p50_days,
    round(quantile_cont(age_days, 0.75), 2)         AS p75_days,
    round(quantile_cont(age_days, 0.90), 2)         AS p90_days,
    round(quantile_cont(age_days, 0.95), 2)         AS p95_days,
    round(avg(age_days), 2)                         AS mean_days
FROM pr_matched
WHERE age_days IS NOT NULL
GROUP BY action
ORDER BY n DESC;


-- 5. The same curve for issues. fact_issue has the identical problem, and
--    issues are expected to run longer than pull requests -- worth knowing
--    before assuming one window suits both.
CREATE OR REPLACE TEMP TABLE iss_matched AS
SELECT
    c.subject_id,
    c.created_at AS closed_at,
    epoch(c.created_at - o.opened_at) / 86400.0 AS age_days
FROM hist c
LEFT JOIN (
    SELECT subject_id, min(created_at) AS opened_at
    FROM hist WHERE event_type = 'IssuesEvent' AND action = 'opened'
    GROUP BY subject_id
) o ON o.subject_id = c.subject_id AND o.opened_at < c.created_at
WHERE c.event_type = 'IssuesEvent'
  AND c.action = 'closed'
  AND c.created_at >= (SELECT max(created_at) - INTERVAL 7 DAY FROM hist);

SELECT
    k                                                              AS lookback_days,
    count(*)                                                       AS closes_in_sample,
    round(100.0 * count(*) FILTER (WHERE age_days IS NOT NULL AND age_days <= k)
          / nullif(count(*), 0), 1)                                AS pct_measurable_issues
FROM iss_matched
CROSS JOIN (SELECT unnest([1,7,14,30,60,90,105]) AS k) ks
GROUP BY k
ORDER BY k;
