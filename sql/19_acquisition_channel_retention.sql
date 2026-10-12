
-- Step 19: Acquisition Channel Retention Analysis
-- Compare November and December W1 retention
-- Use first-user acquisition attribution

WITH session_events AS (

    SELECT
        user_pseudo_id AS user_id,
        event_timestamp,

        DATE_TRUNC(
            PARSE_DATE('%Y%m%d', event_date),
            WEEK(MONDAY)
        ) AS activity_week,

        LOWER(
            COALESCE(
                NULLIF(TRIM(traffic_source.source), ''),
                '(not set)'
            )
        ) AS source,

        LOWER(
            COALESCE(
                NULLIF(TRIM(traffic_source.medium), ''),
                '(not set)'
            )
        ) AS medium

    FROM
        `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

    WHERE
        _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
        AND event_name = 'session_start'
        AND user_pseudo_id IS NOT NULL
),

-- Find each user's first observed session
first_visit AS (

    SELECT
        user_id,

        ARRAY_AGG(
            STRUCT(activity_week, source, medium)
            ORDER BY event_timestamp, source, medium
            LIMIT 1
        )[OFFSET(0)] AS first_session

    FROM session_events

    GROUP BY user_id
),

-- Build cohorts and standardized channel groups
cohort_users AS (

    SELECT
        user_id,

        first_session.activity_week AS cohort_week,

        CASE
            WHEN first_session.source IN (
                '(not set)', '(data deleted)', '<other>'
            )
            OR first_session.medium IN (
                '(not set)', '(data deleted)', '<other>'
            )
                THEN 'Unattributed / Obfuscated'

            WHEN first_session.source = '(direct)'
                AND first_session.medium = '(none)'
                THEN 'Direct'

            WHEN first_session.medium = 'organic'
                THEN 'Organic Search'

            WHEN first_session.medium = 'referral'
                THEN 'Referral'

            WHEN first_session.medium = 'cpc'
                THEN 'Paid (CPC)'

            ELSE 'Other / Unclassified'
        END AS channel_group

    FROM first_visit

    WHERE
        first_session.activity_week BETWEEN
            DATE '2020-11-02' AND DATE '2020-12-28'
),

-- Identify distinct user active weeks
weekly_activity AS (

    SELECT DISTINCT
        user_id,
        activity_week

    FROM session_events
),

-- Determine W1 return status
user_retention AS (

    SELECT
        c.user_id,
        c.cohort_week,
        c.channel_group,

        IF(a.user_id IS NOT NULL, 1, 0)
            AS returned_w1

    FROM cohort_users c

    LEFT JOIN weekly_activity a
        ON c.user_id = a.user_id
        AND a.activity_week = DATE_ADD(
            c.cohort_week,
            INTERVAL 1 WEEK
        )
),

-- Aggregate by acquisition month and channel
channel_summary AS (

    SELECT
        FORMAT_DATE('%Y-%m', cohort_week)
            AS cohort_month,

        channel_group,

        COUNT(*) AS cohort_users,

        SUM(returned_w1) AS w1_retained_users

    FROM user_retention

    GROUP BY cohort_month, channel_group
)

SELECT
    cohort_month,
    channel_group,
    cohort_users,
    w1_retained_users,

    ROUND(
        100 * SAFE_DIVIDE(
            w1_retained_users,
            cohort_users
        ), 2
    ) AS w1_retention_pct,

    ROUND(
        100 * SAFE_DIVIDE(
            cohort_users,
            SUM(cohort_users) OVER (
                PARTITION BY cohort_month
            )
        ), 2
    ) AS channel_share_pct

FROM channel_summary

ORDER BY
    cohort_month,
    cohort_users DESC;
