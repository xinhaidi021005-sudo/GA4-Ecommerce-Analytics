
-- Step 21: First-Session Behavior Feature Engineering
-- Target: Week 1 retention
-- Features: First observed session only

WITH session_starts AS (

    SELECT
        user_pseudo_id AS user_id,
        event_timestamp AS start_ts,

        DATE_TRUNC(
            PARSE_DATE('%Y%m%d', event_date),
            WEEK(MONDAY)
        ) AS activity_week,

        COALESCE(
            device.category, 'unknown'
        ) AS device_type,

        (
            SELECT ep.value.int_value
            FROM UNNEST(event_params) AS ep
            WHERE ep.key = 'ga_session_id'
            LIMIT 1
        ) AS session_id

    FROM
        `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

    WHERE
        _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
        AND event_name = 'session_start'
        AND user_pseudo_id IS NOT NULL
),

-- Identify first observed session per user
first_sessions AS (

    SELECT
        user_id,

        ARRAY_AGG(
            STRUCT(
                start_ts,
                activity_week,
                device_type,
                session_id
            )
            ORDER BY
                start_ts,
                device_type,
                session_id
            LIMIT 1
        )[OFFSET(0)] AS first_session

    FROM session_starts
    GROUP BY user_id
),

-- Keep complete observation cohorts
cohort_users AS (

    SELECT
        user_id,
        first_session.start_ts AS start_ts,
        first_session.activity_week AS cohort_week,
        first_session.device_type AS device_type,
        first_session.session_id AS session_id

    FROM first_sessions

    WHERE
        first_session.activity_week BETWEEN
            DATE '2020-11-02'
            AND DATE '2020-12-28'
),

-- Create next-week retention label
labeled_users AS (

    SELECT
        c.*,

        IF(
            COUNT(s.user_id) > 0,
            1,
            0
        ) AS returned_w1

    FROM cohort_users c

    LEFT JOIN session_starts s
        ON c.user_id = s.user_id
        AND s.activity_week = DATE_ADD(
            c.cohort_week,
            INTERVAL 1 WEEK
        )

    GROUP BY
        c.user_id,
        c.start_ts,
        c.cohort_week,
        c.device_type,
        c.session_id
),

-- Extract raw events for first-session matching
raw_events AS (

    SELECT
        user_pseudo_id AS user_id,
        event_name,
        event_timestamp,

        DATE_TRUNC(
            PARSE_DATE('%Y%m%d', event_date),
            WEEK(MONDAY)
        ) AS event_week,

        (
            SELECT ep.value.int_value
            FROM UNNEST(event_params) AS ep
            WHERE ep.key = 'ga_session_id'
            LIMIT 1
        ) AS session_id

    FROM
        `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

    WHERE
        _TABLE_SUFFIX BETWEEN '20201102' AND '20210103'
        AND user_pseudo_id IS NOT NULL
),

-- Engineer behavioral features
first_session_features AS (

    SELECT
        u.user_id,

        COUNT(e.event_name) AS event_count,

        COUNTIF(
            e.event_name = 'page_view'
        ) AS page_views,

        COUNTIF(
            e.event_name = 'view_item'
        ) AS item_views,

        COUNTIF(
            e.event_name = 'add_to_cart'
        ) AS cart_events,

        COUNTIF(
            e.event_name = 'begin_checkout'
        ) AS checkout_events,

        COUNTIF(
            e.event_name = 'purchase'
        ) AS purchase_events,

        COUNT(DISTINCT e.event_name)
            AS distinct_event_types

    FROM labeled_users u

    LEFT JOIN raw_events e
        ON u.user_id = e.user_id
        AND u.session_id = e.session_id
        AND e.event_timestamp >= u.start_ts
        AND e.event_week = u.cohort_week

    GROUP BY u.user_id
)

-- Audit behavior features by month and device
SELECT
    FORMAT_DATE(
        '%Y-%m', u.cohort_week
    ) AS cohort_month,

    u.device_type,

    COUNT(*) AS cohort_users,

    COUNTIF(u.returned_w1 = 1)
        AS w1_retained_users,

    ROUND(
        100 * SAFE_DIVIDE(
            COUNTIF(u.returned_w1 = 1),
            COUNT(*)
        ), 2
    ) AS w1_retention_pct,

    ROUND(
        AVG(f.event_count), 2
    ) AS avg_first_session_events,

    ROUND(
        AVG(f.page_views), 2
    ) AS avg_page_views,

    ROUND(
        100 * SAFE_DIVIDE(
            COUNTIF(f.item_views > 0),
            COUNT(*)
        ), 2
    ) AS item_view_user_pct,

    ROUND(
        100 * SAFE_DIVIDE(
            COUNTIF(f.cart_events > 0),
            COUNT(*)
        ), 2
    ) AS cart_user_pct,

    ROUND(
        100 * SAFE_DIVIDE(
            COUNTIF(f.purchase_events > 0),
            COUNT(*)
        ), 2
    ) AS purchase_user_pct,

    COUNTIF(u.session_id IS NULL)
        AS missing_session_id_users,

    COUNTIF(f.event_count = 0)
        AS users_without_matched_events

FROM labeled_users u

INNER JOIN first_session_features f
    ON u.user_id = f.user_id

GROUP BY
    cohort_month,
    u.device_type

ORDER BY
    cohort_month,
    cohort_users DESC;
