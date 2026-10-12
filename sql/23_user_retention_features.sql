
-- Step 23: Build User-Level Retention Feature Table
-- Dataset: Google GA4 E-commerce
-- Feature window: First observed session
-- Target: Week 1 retention
-- One row per user

CREATE OR REPLACE TABLE
`ga4-ecommerce-analytics-511204.ga4_analytics.user_retention_features`

OPTIONS (
    description = 'First-session behavior features for W1 retention'
)

AS

WITH session_starts AS (

    -- 1. Extract session start events
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

first_sessions AS (

    -- 2. Find first observed session per user
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

cohort_users AS (

    -- 3. Keep cohorts with complete W1 observation
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

weekly_activity AS (

    -- 4. Identify distinct active user weeks
    SELECT DISTINCT
        user_id,
        activity_week

    FROM session_starts

),

labeled_users AS (

    -- 5. Create W1 retention target
    SELECT
        c.*,

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

raw_events AS (

    -- 6. Extract events eligible for first-session features
    SELECT
        user_pseudo_id AS user_id,
        event_timestamp,
        event_name,

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

first_session_features AS (

    -- 7. Aggregate event-level data to user-level features
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

        COUNTIF(
            e.event_name = 'user_engagement'
        ) AS engagement_events,

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

-- 8. Create final machine learning dataset
SELECT
    u.user_id,
    u.cohort_week,

    FORMAT_DATE(
        '%Y-%m',
        u.cohort_week
    ) AS cohort_month,

    u.device_type,

    TIMESTAMP_MICROS(
        u.start_ts
    ) AS first_session_time,

    u.session_id AS first_session_id,

    f.event_count,
    f.page_views,
    f.item_views,
    f.cart_events,
    f.checkout_events,
    f.purchase_events,
    f.engagement_events,
    f.distinct_event_types,

    -- Data quality flags
    IF(
        u.session_id IS NOT NULL,
        TRUE,
        FALSE
    ) AS has_session_id,

    IF(
        f.event_count > 0,
        TRUE,
        FALSE
    ) AS has_matched_events,

    -- Prediction target
    u.returned_w1

FROM labeled_users u

INNER JOIN first_session_features f
    ON u.user_id = f.user_id;
