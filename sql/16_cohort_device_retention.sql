
-- Step 16: Cohort x Device Retention Analysis
-- Analyze cohort composition and W1 retention
-- Date range: 2020-11-01 to 2021-01-31

WITH session_events AS (

    SELECT
        user_pseudo_id AS user_id,
        event_timestamp,

        DATE_TRUNC(
            PARSE_DATE('%Y%m%d', event_date),
            WEEK(MONDAY)
        ) AS activity_week,

        COALESCE(
            device.category, 'unknown'
        ) AS device_type

    FROM
        `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

    WHERE
        _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
        AND event_name = 'session_start'
        AND user_pseudo_id IS NOT NULL
),

-- Step 1: Identify the first observed session
first_visit AS (

    SELECT
        user_id,

        ARRAY_AGG(
            STRUCT(
                activity_week AS cohort_week,
                device_type AS first_device
            )
            ORDER BY event_timestamp, device_type
            LIMIT 1
        )[OFFSET(0)] AS first_session

    FROM session_events

    GROUP BY user_id
),

-- Step 2: Define cohort and device
cohort_users AS (

    SELECT
        user_id,
        first_session.cohort_week AS cohort_week,
        first_session.first_device AS device_type

    FROM first_visit

    WHERE
        first_session.cohort_week BETWEEN
            DATE '2020-11-02' AND DATE '2020-12-28'
),

-- Step 3: Identify weekly returning users
weekly_activity AS (

    SELECT DISTINCT
        user_id,
        activity_week

    FROM session_events
),

-- Step 4: Flag W1 return for each user
user_retention AS (

    SELECT
        c.user_id,
        c.cohort_week,
        c.device_type,

        IF(
            a.user_id IS NOT NULL,
            1,
            0
        ) AS returned_w1

    FROM cohort_users c

    LEFT JOIN weekly_activity a
        ON c.user_id = a.user_id
        AND a.activity_week = DATE_ADD(
            c.cohort_week,
            INTERVAL 1 WEEK
        )
),

-- Step 5: Aggregate by cohort and device
cohort_device_summary AS (

    SELECT
        cohort_week,
        device_type,

        COUNT(*) AS cohort_users,

        SUM(returned_w1) AS w1_retained_users

    FROM user_retention

    GROUP BY
        cohort_week,
        device_type
)

-- Step 6: Calculate device share and retention
SELECT
    cohort_week,
    device_type,
    cohort_users,
    w1_retained_users,

    ROUND(
        100 * SAFE_DIVIDE(
            cohort_users,
            SUM(cohort_users) OVER (
                PARTITION BY cohort_week
            )
        ),
        2
    ) AS device_share_pct,

    ROUND(
        100 * SAFE_DIVIDE(
            w1_retained_users,
            cohort_users
        ),
        2
    ) AS w1_retention_pct

FROM cohort_device_summary

ORDER BY
    cohort_week,
    device_type;
