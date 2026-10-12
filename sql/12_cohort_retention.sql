-- Step 12: Weekly Cohort Retention Analysis
-- Dataset: Google GA4 E-commerce
-- Activity: session_start
-- Retention window: Week 0 to Week 4

WITH user_weekly_activity AS (
    -- Step 1: Identify weekly active users
    SELECT DISTINCT
        user_pseudo_id AS user_id,
        DATE_TRUNC(
            PARSE_DATE('%Y%m%d', event_date),
            WEEK(MONDAY)
        ) AS activity_week
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
      AND event_name = 'session_start'
      AND user_pseudo_id IS NOT NULL
),
user_cohorts AS (
    -- Step 2: Identify each user's first observed week
    SELECT
        user_id,
        MIN(activity_week) AS cohort_week
    FROM user_weekly_activity
    GROUP BY user_id
),
cohort_sizes AS (
    -- Step 3: Count users in each cohort
    SELECT
        cohort_week,
        COUNT(*) AS cohort_size
    FROM user_cohorts
    WHERE cohort_week BETWEEN DATE '2020-11-02' AND DATE '2020-12-28'
    GROUP BY cohort_week
),
weekly_retention AS (
    -- Step 4: Count returning users by week
    SELECT
        c.cohort_week,
        DATE_DIFF(
            a.activity_week,
            c.cohort_week,
            WEEK(MONDAY)
        ) AS week_number,
        COUNT(DISTINCT a.user_id) AS retained_users
    FROM user_weekly_activity a
    INNER JOIN user_cohorts c
        ON a.user_id = c.user_id
    WHERE c.cohort_week BETWEEN DATE '2020-11-02' AND DATE '2020-12-28'
      AND DATE_DIFF(
            a.activity_week,
            c.cohort_week,
            WEEK(MONDAY)
          ) BETWEEN 0 AND 4
    GROUP BY c.cohort_week, week_number
),
cohort_weeks AS (
    -- Step 5: Include weeks with zero returning users
    SELECT
        c.cohort_week,
        c.cohort_size,
        week_number
    FROM cohort_sizes c
    CROSS JOIN UNNEST(GENERATE_ARRAY(0, 4)) AS week_number
)

-- Step 6: Calculate retention rates
SELECT
    cw.cohort_week,
    cw.week_number,
    cw.cohort_size,
    COALESCE(wr.retained_users, 0) AS retained_users,
    ROUND(
        100 * SAFE_DIVIDE(
            COALESCE(wr.retained_users, 0),
            cw.cohort_size
        ),
        2
    ) AS retention_rate_pct
FROM cohort_weeks cw
LEFT JOIN weekly_retention wr
    ON cw.cohort_week = wr.cohort_week
   AND cw.week_number = wr.week_number
ORDER BY
    cw.cohort_week,
    cw.week_number;
