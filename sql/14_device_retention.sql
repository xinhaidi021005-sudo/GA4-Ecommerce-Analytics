
-- Step 14: Retention Analysis by Device
-- Compare W1 and W4 retention
-- Assign device based on first observed session

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

-- Step 2: Assign each user to one cohort and device
cohort_users AS (

    SELECT
        user_id,
        first_session.cohort_week AS cohort_week,
        first_session.first_device AS first_device

    FROM first_visit

    WHERE
        first_session.cohort_week BETWEEN
            DATE '2020-11-02' AND DATE '2020-12-28'

),

-- Step 3: Identify distinct active weeks
weekly_activity AS (

    SELECT DISTINCT
        user_id,
        activity_week

    FROM session_events

),

-- Step 4: Calculate retention per user
user_retention AS (

    SELECT
        c.user_id,
        c.cohort_week,
        c.first_device,

        MAX(
            IF(
                a.activity_week = DATE_ADD(
                    c.cohort_week,
                    INTERVAL 1 WEEK
                ),
                1, 0
            )
        ) AS returned_w1,

        MAX(
            IF(
                a.activity_week = DATE_ADD(
                    c.cohort_week,
                    INTERVAL 4 WEEK
                ),
                1, 0
            )
        ) AS returned_w4

    FROM cohort_users c

    LEFT JOIN weekly_activity a
        ON c.user_id = a.user_id
        AND a.activity_week IN (
            DATE_ADD(c.cohort_week, INTERVAL 1 WEEK),
            DATE_ADD(c.cohort_week, INTERVAL 4 WEEK)
        )

    GROUP BY
        c.user_id,
        c.cohort_week,
        c.first_device

)

-- Step 5: Calculate retention rates by device
SELECT
    first_device AS device_type,

    COUNT(*) AS cohort_users,

    SUM(returned_w1) AS w1_retained_users,

    ROUND(
        100 * SAFE_DIVIDE(
            SUM(returned_w1),
            COUNT(*)
        ), 2
    ) AS w1_retention_pct,

    SUM(returned_w4) AS w4_retained_users,

    ROUND(
        100 * SAFE_DIVIDE(
            SUM(returned_w4),
            COUNT(*)
        ), 2
    ) AS w4_retention_pct

FROM user_retention

GROUP BY first_device

ORDER BY cohort_users DESC;
