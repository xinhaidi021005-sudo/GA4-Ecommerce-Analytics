
-- Step 5: Sequential E-commerce Conversion Funnel
-- Date range: 2020-12-01 to 2020-12-07
-- Analysis unit: Session

WITH base_events AS (

    SELECT
        user_pseudo_id AS user_id,
        event_name,
        event_timestamp,

        (
            SELECT ep.value.int_value
            FROM UNNEST(event_params) AS ep
            WHERE ep.key = 'ga_session_id'
            LIMIT 1
        ) AS session_id

    FROM
        `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

    WHERE
        _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
        AND user_pseudo_id IS NOT NULL
        AND event_name IN (
            'view_item',
            'add_to_cart',
            'begin_checkout',
            'purchase'
        )

),

events AS (

    SELECT
        CONCAT(
            user_id, '.',
            CAST(session_id AS STRING)
        ) AS session_key,
        event_name,
        event_timestamp

    FROM base_events
    WHERE session_id IS NOT NULL

),

-- Stage 1: First item view
view_step AS (

    SELECT
        session_key,
        MIN(event_timestamp) AS view_ts

    FROM events
    WHERE event_name = 'view_item'
    GROUP BY session_key

),

-- Stage 2: First add to cart after item view
cart_step AS (

    SELECT
        v.session_key,
        v.view_ts,
        MIN(e.event_timestamp) AS cart_ts

    FROM view_step v

    LEFT JOIN events e
        ON v.session_key = e.session_key
        AND e.event_name = 'add_to_cart'
        AND e.event_timestamp > v.view_ts

    GROUP BY v.session_key, v.view_ts

),

-- Stage 3: First checkout after add to cart
checkout_step AS (

    SELECT
        c.session_key,
        c.view_ts,
        c.cart_ts,
        MIN(e.event_timestamp) AS checkout_ts

    FROM cart_step c

    LEFT JOIN events e
        ON c.session_key = e.session_key
        AND e.event_name = 'begin_checkout'
        AND e.event_timestamp > c.cart_ts

    GROUP BY c.session_key, c.view_ts, c.cart_ts

),

-- Stage 4: First purchase after checkout
purchase_step AS (

    SELECT
        c.session_key,
        c.view_ts,
        c.cart_ts,
        c.checkout_ts,
        MIN(e.event_timestamp) AS purchase_ts

    FROM checkout_step c

    LEFT JOIN events e
        ON c.session_key = e.session_key
        AND e.event_name = 'purchase'
        AND e.event_timestamp > c.checkout_ts

    GROUP BY
        c.session_key,
        c.view_ts,
        c.cart_ts,
        c.checkout_ts

),

-- Count sessions reaching each stage
summary AS (

    SELECT
        COUNT(*) AS view_sessions,

        COUNTIF(cart_ts IS NOT NULL)
            AS cart_sessions,

        COUNTIF(checkout_ts IS NOT NULL)
            AS checkout_sessions,

        COUNTIF(purchase_ts IS NOT NULL)
            AS purchase_sessions

    FROM purchase_step

),

funnel AS (

    SELECT 1 AS step, 'view_item' AS stage,
           view_sessions AS sessions FROM summary

    UNION ALL

    SELECT 2, 'add_to_cart',
           cart_sessions FROM summary

    UNION ALL

    SELECT 3, 'begin_checkout',
           checkout_sessions FROM summary

    UNION ALL

    SELECT 4, 'purchase',
           purchase_sessions FROM summary

)

SELECT
    step,
    stage,
    sessions,

    ROUND(
        100 * SAFE_DIVIDE(
            sessions,
            LAG(sessions) OVER (ORDER BY step)
        ),
        2
    ) AS step_conversion_pct,

    ROUND(
        100 * SAFE_DIVIDE(
            sessions,
            FIRST_VALUE(sessions) OVER (
                ORDER BY step
            )
        ),
        2
    ) AS overall_conversion_pct

FROM funnel

ORDER BY step;
