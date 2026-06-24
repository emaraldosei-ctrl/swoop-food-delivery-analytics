/* =====================================================================
   SWOOP  |  SQL DATA ANALYSIS
   Food delivery platform  ·  PostgreSQL
   ---------------------------------------------------------------------
   Business goal: turn Swoop's raw order data into insights on revenue,
   customers, retention and operations, to feed a Power BI dashboard.

   Convention used throughout: revenue = DELIVERED orders only, because
   cancelled or pending orders are not realised revenue.

   Tables used: orders, order_items, meals.
   Author: Esmeralda Pinamang Osei
   ===================================================================== */


/* =====================================================================
   OBJECTIVE 1  —  REVENUE TRACKING
   ===================================================================== */

-- 1.1  Total revenue (all delivered orders)
-- Purpose: the headline revenue figure for the business.
-- Result: ~$2.53M.
SELECT
    ROUND(SUM(total_amount)::numeric, 2) AS total_revenue
FROM orders
WHERE order_status = 'delivered';


-- 1.2  Revenue and gross profit in the latest month
-- Purpose: how much Swoop sold and kept (after food cost) last month.
-- Method: find the most recent month, then for that month sum item
--         revenue and the cost to make each meal; profit = revenue - cost.
-- Result: ~$296,289 revenue and ~$165,201 gross profit (December).
WITH latest_month AS (
    SELECT DATE_TRUNC('month', MAX(order_date)) AS month_start
    FROM orders
),
item_profit AS (
    SELECT
        o.order_id,
        SUM(oi.subtotal)                   AS item_revenue,
        SUM(oi.quantity * m.cost_to_make)  AS total_meal_cost
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    JOIN meals m        ON oi.meal_id = m.meal_id
    CROSS JOIN latest_month lm
    WHERE o.order_date >= lm.month_start
      AND o.order_date <  lm.month_start + INTERVAL '1 month'
      AND o.order_status = 'delivered'
    GROUP BY o.order_id
)
SELECT
    SUM(item_revenue)                      AS total_revenue,
    SUM(total_meal_cost)                   AS total_meal_cost,
    SUM(item_revenue - total_meal_cost)    AS gross_profit
FROM item_profit;


-- 1.3  Revenue and profit by meal category
-- Purpose: which food categories earn the most.
-- Method: join orders -> order_items -> meals, then group by category.
-- Result: Dinner leads (~$1.22M), then Lunch, Snacks, etc.
SELECT
    m.category,
    SUM(oi.subtotal)                                   AS total_revenue,
    SUM(oi.quantity * m.cost_to_make)                  AS total_cost,
    SUM(oi.subtotal - (oi.quantity * m.cost_to_make))  AS gross_profit
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN meals m        ON oi.meal_id = m.meal_id
WHERE o.order_status = 'delivered'
GROUP BY m.category
ORDER BY total_revenue DESC;


-- 1.4  Average order value by time of day
-- Purpose: do customers spend more at certain times?
-- Method: bucket the order hour into Morning/Afternoon/Evening/Night.
-- Result: fairly flat (~$100 across all buckets) — time of day matters little.
SELECT
    CASE
        WHEN EXTRACT(HOUR FROM order_date) BETWEEN 5  AND 11 THEN 'Morning'
        WHEN EXTRACT(HOUR FROM order_date) BETWEEN 12 AND 16 THEN 'Afternoon'
        WHEN EXTRACT(HOUR FROM order_date) BETWEEN 17 AND 21 THEN 'Evening'
        ELSE 'Night'
    END                              AS time_of_day,
    COUNT(order_id)                  AS total_orders,
    ROUND(AVG(total_amount), 2)      AS avg_revenue_per_order
FROM orders
WHERE order_status = 'delivered'
GROUP BY time_of_day
ORDER BY avg_revenue_per_order DESC;


/* =====================================================================
   OBJECTIVE 2  —  CUSTOMER BEHAVIOUR  (active users)
   ===================================================================== */

-- 2.1  Active users over the last 3 months
-- Purpose: how many distinct customers ordered, and the recent trend.
-- Key point: COUNT(DISTINCT user_id) counts PEOPLE, not orders.
-- Result: active users rise across the last quarter.
WITH latest_date AS (
    SELECT MAX(order_date) AS max_order_date
    FROM orders
)
SELECT
    DATE_TRUNC('month', o.order_date)::DATE                       AS order_month,
    COUNT(DISTINCT o.user_id)                                     AS active_users,
    COUNT(o.order_id)                                             AS total_orders,
    ROUND(COUNT(o.order_id)::NUMERIC
          / COUNT(DISTINCT o.user_id), 2)                         AS avg_orders_per_active_user
FROM orders o
CROSS JOIN latest_date ld
WHERE o.order_date >= DATE_TRUNC('month', ld.max_order_date) - INTERVAL '2 months'
  AND o.order_date <  DATE_TRUNC('month', ld.max_order_date) + INTERVAL '1 month'
  AND o.order_status = 'delivered'
GROUP BY DATE_TRUNC('month', o.order_date)
ORDER BY order_month;


/* =====================================================================
   OBJECTIVE 2  —  CUSTOMER SEGMENTATION  (high-value customers)
   ===================================================================== */

-- 3.1  Rank every customer by spend and order count
-- Purpose: identify the highest-value customers (frequency + monetary).
SELECT
    user_id,
    COUNT(order_id)              AS total_orders,
    ROUND(SUM(total_amount), 2)  AS total_spend
FROM orders
WHERE order_status = 'delivered'
GROUP BY user_id
ORDER BY total_spend DESC, total_orders DESC;


-- 3.2  How many customers are there in total?
-- Purpose: the base needed to work out the "top 10%".
-- Result: 2,485 customers (so the top 10% is ~248 customers).
SELECT COUNT(DISTINCT user_id) AS total_customers
FROM orders
WHERE order_status = 'delivered';


-- 3.3  The top 10% of customers by spend
-- Purpose: list only the highest-value decile of customers.
-- Method: LIMIT to 10% of the customer count, computed dynamically.
-- Result: ~248 customers who drive ~38% of all revenue.
SELECT
    user_id,
    COUNT(order_id)              AS total_orders,
    ROUND(SUM(total_amount), 2)  AS total_spend
FROM orders
WHERE order_status = 'delivered'
GROUP BY user_id
ORDER BY total_spend DESC, total_orders DESC
LIMIT (
    SELECT CEIL(COUNT(DISTINCT user_id) * 0.10)
    FROM orders
    WHERE order_status = 'delivered'
);


-- 3.4  What these customers buy most (meal preference)
-- Purpose: which categories generate the most revenue.
SELECT
    m.category,
    COUNT(*)                     AS number_of_orders,
    ROUND(SUM(oi.subtotal), 2)   AS revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN meals m        ON oi.meal_id = m.meal_id
WHERE o.order_status = 'delivered'
GROUP BY m.category
ORDER BY revenue DESC;


/* =====================================================================
   OBJECTIVE 2  —  CUSTOMER RETENTION
   ===================================================================== */

-- 4.1  Returning customers (ordered more than once)
-- Purpose: count customers with repeat orders.
-- Note: HAVING filters groups AFTER aggregating — here, keep only
--       customers whose order count is greater than 1.
SELECT COUNT(*) AS returning_customers
FROM (
    SELECT user_id
    FROM orders
    WHERE order_status = 'delivered'
    GROUP BY user_id
    HAVING COUNT(order_id) > 1
) AS repeat_customers;


-- 4.2  Overall retention rate (lifetime repeat rate)
-- Purpose: share of customers who ordered more than once.
-- Formula: returning customers / total customers * 100.
-- Result: ~93.32%.
SELECT
    ROUND(
        COUNT(DISTINCT CASE
            WHEN user_id IN (
                SELECT user_id
                FROM orders
                WHERE order_status = 'delivered'
                GROUP BY user_id
                HAVING COUNT(order_id) > 1
            ) THEN user_id
        END) * 100.0
        / COUNT(DISTINCT user_id),
    2) AS retention_rate
FROM orders
WHERE order_status = 'delivered';


-- 4.3  Customers grouped by order frequency
-- Purpose: split customers into One-time / Regular / Loyal groups.
-- Method: the inner query classifies each customer by their order count;
--         the outer query counts how many customers fall in each group.
-- (Corrected: counting must happen AFTER each customer is classified.)
SELECT
    customer_segment,
    COUNT(*) AS number_of_customers
FROM (
    SELECT
        user_id,
        CASE
            WHEN COUNT(order_id) = 1            THEN 'One-time Customer'
            WHEN COUNT(order_id) BETWEEN 2 AND 5 THEN 'Regular Customer'
            ELSE 'Loyal Customer'
        END AS customer_segment
    FROM orders
    WHERE order_status = 'delivered'
    GROUP BY user_id
) AS per_customer
GROUP BY customer_segment
ORDER BY number_of_customers DESC;


/* =====================================================================
   REUSABLE VIEWS  —  these feed the Power BI dashboard directly
   A VIEW is a saved query that can be queried like a table and always
   reflects the current data.
   ===================================================================== */

-- 5.1  revenue_summary — total revenue per day
CREATE OR REPLACE VIEW revenue_summary AS
SELECT
    DATE(order_date)     AS order_day,
    SUM(total_amount)    AS total_revenue
FROM orders
WHERE order_status = 'delivered'
GROUP BY DATE(order_date);


-- 5.2  retention_by_segment — quarter-over-quarter retention,
--      top 10% of customers vs the rest.
-- Purpose: which value segment retains best.
-- Result: Top 10% ~99% vs Bottom 90% ~85%.
CREATE OR REPLACE VIEW retention_by_segment AS
WITH q AS (SELECT DATE_TRUNC('quarter', MAX(order_date)) AS lq FROM orders),
prior_spend AS (
    SELECT user_id, SUM(total_amount) AS spend
    FROM orders o, q
    WHERE o.order_status = 'delivered' AND o.order_date < q.lq
    GROUP BY user_id),
tier AS (
    SELECT user_id, NTILE(10) OVER (ORDER BY spend DESC) AS d
    FROM prior_spend),
prev_q AS (
    SELECT DISTINCT user_id FROM orders o, q
    WHERE o.order_status = 'delivered'
      AND DATE_TRUNC('quarter', o.order_date) = q.lq - INTERVAL '3 months'),
last_q AS (
    SELECT DISTINCT user_id FROM orders o, q
    WHERE o.order_status = 'delivered'
      AND DATE_TRUNC('quarter', o.order_date) = q.lq)
SELECT
    CASE WHEN t.d = 1 THEN 'Top 10% value' ELSE 'Bottom 90%' END AS segment,
    ROUND(100.0 * COUNT(l.user_id) / COUNT(*), 1)               AS retention_pct
FROM prev_q p
JOIN tier t      ON t.user_id = p.user_id
LEFT JOIN last_q l ON l.user_id = p.user_id
GROUP BY 1;


-- 5.3  rfm_segments — RFM customer segmentation
-- Purpose: score each customer on Recency, Frequency and Monetary value
--          (1-5 each) and assign a named, actionable segment.
-- Note: recency is inverted (6 - NTILE) so a recent order scores HIGH,
--       because "days since last order" is a SMALL number for active users.
-- Result: Champion 445, Needs Attention 497, Hibernating 637, etc.
CREATE OR REPLACE VIEW rfm_segments AS
WITH base AS (
    SELECT
        o.user_id,
        COUNT(*)               AS frequency,
        SUM(o.total_amount)    AS monetary,
        (SELECT MAX(order_date)::date FROM orders) - MAX(o.order_date)::date AS recency_days
    FROM orders o
    WHERE o.order_status = 'delivered'
    GROUP BY o.user_id),
scored AS (
    SELECT *,
        6 - NTILE(5) OVER (ORDER BY recency_days) AS r,   -- recent   = 5
        NTILE(5)     OVER (ORDER BY frequency)    AS f,   -- frequent = 5
        NTILE(5)     OVER (ORDER BY monetary)     AS m    -- big spend = 5
    FROM base)
SELECT user_id, frequency, monetary, segment
FROM (
    SELECT *,
        CASE
            WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Champion'
            WHEN r >= 4 AND f >= 3            THEN 'Loyal'
            WHEN r >= 4 AND f <= 2            THEN 'Promising / New'
            WHEN r <= 2 AND f >= 4 AND m >= 4 THEN 'Cannot Lose Them'
            WHEN r <= 2 AND f >= 3            THEN 'At Risk'
            WHEN r <= 2 AND f <= 2            THEN 'Hibernating'
            ELSE 'Needs Attention'
        END AS segment
    FROM scored) s;


-- Check the RFM view: customers and revenue per segment
SELECT
    segment,
    COUNT(*)                AS customers,
    ROUND(SUM(monetary), 0) AS revenue
FROM rfm_segments
GROUP BY segment
ORDER BY customers DESC;

/* =====================  END OF ANALYSIS  ===================== */
