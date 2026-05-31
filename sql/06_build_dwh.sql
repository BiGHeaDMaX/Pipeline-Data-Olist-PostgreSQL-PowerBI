-----------------------------
-- Création des tables DWH --
-----------------------------

-----------------------------
--        dim_dates        --
-----------------------------

-- Ça permettra de relier les faits à une dimension date
-- plutôt que manipuler les timestamps bruts partout dans Power BI.
-- Grain : 1 ligne = 1 jour.
-- Clé : YYYYMMDD
DROP TABLE IF EXISTS dwh.dim_dates;

CREATE TABLE dwh.dim_dates (
    date_key INT PRIMARY KEY,
    full_date DATE NOT NULL,
    year INT NOT NULL,
	iso_year INT NOT NULL,
    quarter INT NOT NULL,
    month INT NOT NULL,
    day INT NOT NULL,
    month_name TEXT NOT NULL,
    day_of_week INT NOT NULL,
    day_name TEXT NOT NULL,
    iso_week_of_year INT NOT NULL,
    is_weekend BOOLEAN NOT NULL
);

-- On récupère min/max date de nos différentes tables.
-- Ça nous servira pour générer la series.
WITH bounds AS (
    SELECT
        MIN(date_value) AS min_date,
        MAX(date_value) AS max_date
    FROM (
        SELECT purchase_ts::date AS date_value FROM stg.orders
        UNION ALL
        SELECT approved_ts::date FROM stg.orders
        UNION ALL
        SELECT delivered_carrier_ts::date FROM stg.orders
        UNION ALL
        SELECT delivered_customer_ts::date FROM stg.orders
        UNION ALL
        SELECT estimated_delivery_ts::date FROM stg.orders
        UNION ALL
        SELECT review_creation_ts::date FROM stg.order_reviews
    ) d
    WHERE date_value IS NOT NULL
)

INSERT INTO dwh.dim_dates
SELECT
    TO_CHAR(d::date,'YYYYMMDD')::int AS date_key,
    d::date AS full_date,
    -- année calendrier
    EXTRACT(YEAR FROM d)::int AS year,
    -- année ISO (pour cohérence avec semaine ISO)
    EXTRACT(ISOYEAR FROM d)::int AS iso_year,
    EXTRACT(QUARTER FROM d)::int AS quarter,  -- Pas d'ISO pour quarter.
    EXTRACT(MONTH FROM d)::int AS month,
    EXTRACT(DAY FROM d)::int AS day,
    TRIM(TO_CHAR(d,'Month')) AS month_name,  -- TRIM car PostgreSQL padde les noms de mois
    EXTRACT(ISODOW FROM d)::int AS day_of_week,  -- ISODOW : Lundi=1 et Dimanche=7
    TRIM(TO_CHAR(d,'Day')) AS day_name,  -- TRIM, pareil pour les noms de jours
    EXTRACT(WEEK FROM d)::int AS iso_week_of_year,  -- Déjà ISO
    CASE
        WHEN EXTRACT(ISODOW FROM d) IN (6,7)
        THEN TRUE
        ELSE FALSE
    END AS is_weekend
FROM bounds,
generate_series(bounds.min_date, bounds.max_date, interval '1 day') d;

--------------------------------
-- dim_dates - Quality checks --
--------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'dim_dates' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.dim_dates;



----------------------------
--      dim_products      --
----------------------------
DROP TABLE IF EXISTS dwh.dim_products;

CREATE TABLE dwh.dim_products (
	-- On va créer une surrogate key (clé substitut) qui sera la PK.
	-- PostgreSQL génèrera toujours (ALWAYS) automatiquement les valeurs de cette clé technique.
	-- Comme ça on se protège des futurs changements de format et de collision
	-- et les jointures seront simplifiées (INT plus rapide que les valeurs longues)
    product_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- Surrogate key (clé technique)
    product_id TEXT NOT NULL,  -- Clé métier (business key)
    product_category_name TEXT,
    product_category_name_english TEXT,
    product_name_lenght INT,
    product_description_lenght INT,
    product_photos_qty INT,
    product_weight_g INT,
    product_length_cm INT,
    product_height_cm INT,
    product_width_cm INT,

    CONSTRAINT uq_dim_products_product_id UNIQUE (product_id)  -- Contrainte product_id, notre business key
);

INSERT INTO dwh.dim_products (
    product_id,
    product_category_name,
    product_category_name_english,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm
)
SELECT
    p.product_id,
    p.product_category_name,
    t.product_category_name_english,
    p.product_name_lenght,
    p.product_description_lenght,
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM stg.products p
-- LEFT : garder tous les produits, même si une traduction est absente
LEFT JOIN stg.product_category_name_translation t
  ON t.product_category_name = p.product_category_name;


-------------------------------------
--  dim_products - Quality checks  --
-------------------------------------

-- Des lignes ont-elles été chargées ?
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'dim_products' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.dim_products;

-- Traduction manquante ?
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'dim_products' AS table_name,
  'null_category_translation' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM dwh.dim_products
WHERE product_category_name IS NOT NULL
  AND product_category_name_english IS NULL;



---------------------------
--     dim_customers     --
---------------------------
DROP TABLE IF EXISTS dwh.dim_customers;
-- On va considérer customer_id business key et non pas customer_unique_id
-- car les faits remontent naturellement à customer_id via orders.
-- Donc pour garder les jointures simples, autant construire dim_customers sur customer_id,
-- tout en gardant customer_unique_id pour l’analyse client réel.
CREATE TABLE dwh.dim_customers (
    customer_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- Surrogate key (clé technique)
    customer_id TEXT NOT NULL,  -- On considère cette clé comme business key
    customer_unique_id TEXT NOT NULL,  -- Conservé comme attribut métier et clé métier alternative possible
    customer_zip_code_prefix TEXT,
    customer_city TEXT,
    customer_state TEXT,

    CONSTRAINT uq_dim_customers_customer_id UNIQUE (customer_id)  -- Contrainte sur notre business key
);

INSERT INTO dwh.dim_customers (
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
)
SELECT
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
FROM stg.customers;

--------------------------------------
--  dim_customers - Quality checks  --
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'dim_customers' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.dim_customers;



-------------------------
--     dim_sellers     --
-------------------------
DROP TABLE IF EXISTS dwh.dim_sellers;

CREATE TABLE dwh.dim_sellers (
    seller_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- Surrogate key (clé technique)
    seller_id TEXT NOT NULL,  -- Business key
    seller_zip_code_prefix TEXT,
    seller_city TEXT,
    seller_state TEXT,

    CONSTRAINT uq_dim_sellers_seller_id UNIQUE (seller_id)
);

INSERT INTO dwh.dim_sellers (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
)
SELECT
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
FROM stg.sellers;

------------------------------------
--  dim_sellers - Quality checks  --
------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'dim_sellers' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.dim_sellers;



--------------------------------
--      fact_order_items      --
--------------------------------
-- C'est notre table de faits principale. C’est elle qui va porter l’analyse business dans Power BI.
-- Grain : 1 ligne = 1 produit dans 1 commande.
-- Donc le grain métier correspond à celui de stg.order_items
-- La fact table doit contenir les clés techniques des dimensions,
-- les mesures et quelques clés métier dégénérées utiles.
-- On part de de stg.order_items, puis on join stg.orders (pour récupérer customer_id,
-- purchase_ts, delivered_customer_ts), dwh.dim_products, dwh.dim_customers, dwh.dim_sellers et dwh.dim_dates
DROP TABLE IF EXISTS dwh.fact_order_items;

CREATE TABLE dwh.fact_order_items (
    fact_order_item_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- Surrogate key (clé technique)

    -- Clés dégénérées
	-- Identifiants métier utiles, stockés directement dans le fait
    order_id TEXT NOT NULL,
    order_item_id INT NOT NULL,

    -- Clés techniques vers dimensions
    product_key INT NOT NULL,
    customer_key INT NOT NULL,
    seller_key INT NOT NULL,
    purchase_date_key INT NOT NULL,
    delivered_customer_date_key INT,

    -- Mesures
    price NUMERIC(12,2) NOT NULL,
    freight_value NUMERIC(12,2) NOT NULL,

    -- Unicité du grain métier
    CONSTRAINT uq_fact_order_items UNIQUE (order_id, order_item_id)
);

INSERT INTO dwh.fact_order_items (
    order_id,
    order_item_id,
    product_key,
    customer_key,
    seller_key,
    purchase_date_key,
    delivered_customer_date_key,
    price,
    freight_value
)
SELECT
    oi.order_id,
    oi.order_item_id,
    dp.product_key,
    dc.customer_key,
    ds.seller_key,
    dd_purchase.date_key AS purchase_date_key,  -- Nous servira à connecter avec dim_date dans Power BI
    dd_delivery.date_key AS delivered_customer_date_key,
    oi.price,
    oi.freight_value
FROM stg.order_items oi
-- JOIN (INNER) car les clés techniques doivent exister
-- pour qu’une ligne de fait soit exploitable.
-- Si une jointure échoue, la ligne disparaît,
-- on va donc ajouter un check DQ (écart de volume avec stg.order_items)
JOIN stg.orders o
  ON o.order_id = oi.order_id
JOIN dwh.dim_products dp
  ON dp.product_id = oi.product_id
JOIN dwh.dim_customers dc
  ON dc.customer_id = o.customer_id
JOIN dwh.dim_sellers ds
  ON ds.seller_id = oi.seller_id
JOIN dwh.dim_dates dd_purchase
  ON dd_purchase.full_date = o.purchase_ts::date
-- LEFT JOIN car certaines commandes ne sont pas encore livrées,
-- sinon on perdrait des lignes.
LEFT JOIN dwh.dim_dates dd_delivery
  ON dd_delivery.full_date = o.delivered_customer_ts::date;

-----------------------------------------
--  fact_order_items - Quality checks  --
-----------------------------------------

-- Des lignes ont-elles été chargées ?
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_items' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.fact_order_items;

-- Écart de volume avec stg.order_items
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_items' AS table_name,
  'missing_rows_vs_stg' AS check_name,
  (
    (SELECT COUNT(*) FROM stg.order_items)
    - (SELECT COUNT(*) FROM dwh.fact_order_items)
  ) AS row_count,
  CASE
    WHEN (
      (SELECT COUNT(*) FROM stg.order_items)
      - (SELECT COUNT(*) FROM dwh.fact_order_items)
    ) = 0
    THEN 'OK'
    ELSE 'WARN'
  END AS status;

-- Prix ou fret manquants ?
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_items' AS table_name,
  'null_price_or_freight' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.fact_order_items
WHERE price IS NULL
   OR freight_value IS NULL;

-- À ce stade, on peut brancher Power BI pour vérifier que notre modèle fonctionne.
-- On ajoutera les autres tables de faits après.
-- -> Ça fonctionne, donc on peut créer les fact tables suivantes.


--------------------------------
--        fact_orders         --
--------------------------------
DROP TABLE IF EXISTS dwh.fact_orders;

CREATE TABLE dwh.fact_orders (
    fact_order_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Clés dégénérées
	-- Identifiants métier utiles, stockés directement dans le fait
    order_id TEXT NOT NULL,

    -- Clés techniques vers dimensions
    customer_key INT NOT NULL,
    purchase_date_key INT NOT NULL,
    approved_date_key INT,
    delivered_carrier_date_key INT,
    delivered_customer_date_key INT,
    estimated_delivery_date_key INT,

    -- métriques logistiques
    lead_time_days INT,
    shipping_duration_days INT,
    delivery_delay_days INT,

    -- garde-fou
    CONSTRAINT uq_fact_orders UNIQUE (order_id)
);

INSERT INTO dwh.fact_orders (
    order_id,
    customer_key,
    purchase_date_key,
    approved_date_key,
    delivered_carrier_date_key,
    delivered_customer_date_key,
    estimated_delivery_date_key,
    lead_time_days,
    shipping_duration_days,
    delivery_delay_days
)
SELECT
    o.order_id,

    dc.customer_key,

    dd_purchase.date_key,
    dd_approved.date_key,
    dd_carrier.date_key,
    dd_delivery.date_key,
    dd_estimated.date_key,

    o.lead_time_days,
    o.shipping_duration_days,
    o.delivery_delay_days

FROM stg.orders o

JOIN dwh.dim_customers dc
  ON dc.customer_id = o.customer_id

JOIN dwh.dim_dates dd_purchase
  ON dd_purchase.full_date = o.purchase_ts::date

LEFT JOIN dwh.dim_dates dd_approved
  ON dd_approved.full_date = o.approved_ts::date

LEFT JOIN dwh.dim_dates dd_carrier
  ON dd_carrier.full_date = o.delivered_carrier_ts::date

LEFT JOIN dwh.dim_dates dd_delivery
  ON dd_delivery.full_date = o.delivered_customer_ts::date

LEFT JOIN dwh.dim_dates dd_estimated
  ON dd_estimated.full_date = o.estimated_delivery_ts::date;


------------------------------------
--  fact_orders - Quality checks  --
------------------------------------

-- Des lignes ont-elles été chargées ?
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT 'dwh','fact_orders','rows_loaded', COUNT(*),
CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END
FROM dwh.fact_orders;

-- Perte de lignes entre stg.orders et dwh.fact_orders
------------------------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_orders' AS table_name,
  'missing_rows_vs_stg' AS check_name,
  (
    (SELECT COUNT(*) FROM stg.orders)
    - (SELECT COUNT(*) FROM dwh.fact_orders)
  ) AS row_count,
  CASE
    WHEN (
      (SELECT COUNT(*) FROM stg.orders)
      - (SELECT COUNT(*) FROM dwh.fact_orders)
    ) = 0
    THEN 'OK'
    ELSE 'WARN'
  END AS status;




-----------------------------------
--      fact_order_reviews       --
-----------------------------------
-- Grain : 1 ligne = 1 review pour 1 commande
-- On ne prend pas review_comment_title ni review_comment_message dans la fact table.
-- Ça alourdit inutilement le modèle et ce n'est pas très BI-friendly.
DROP TABLE IF EXISTS dwh.fact_order_reviews;

CREATE TABLE dwh.fact_order_reviews (
    fact_order_review_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Clés dégénérées
	-- Identifiants métier utiles, stockés directement dans le fait
    review_id TEXT NOT NULL,
    order_id TEXT NOT NULL,

    -- Clés techniques vers dimensions
    customer_key INT NOT NULL,
    review_creation_date_key INT,
    review_answer_date_key INT,

    -- mesure
    review_score INT,

    -- garde-fou sur le grain métier
	-- review_id seul n’est pas unique, (review_id, order_id) est unique
    CONSTRAINT uq_fact_order_reviews UNIQUE (review_id, order_id)
);

INSERT INTO dwh.fact_order_reviews (
    review_id,
    order_id,
    customer_key,
    review_creation_date_key,
    review_answer_date_key,
    review_score
)
SELECT
    r.review_id,
    r.order_id,
    dc.customer_key,
    dd_creation.date_key AS review_creation_date_key,
    dd_answer.date_key AS review_answer_date_key,
    r.review_score
FROM stg.order_reviews r
JOIN stg.orders o
  ON o.order_id = r.order_id
JOIN dwh.dim_customers dc
  ON dc.customer_id = o.customer_id
-- LEFT JOIN sur les dates, car review_creation_ts peut potentiellement être NULL
-- et review_answer_ts aussi, donc on ne veut pas perdre de lignes pour ça.
LEFT JOIN dwh.dim_dates dd_creation
  ON dd_creation.full_date = r.review_creation_ts::date
LEFT JOIN dwh.dim_dates dd_answer
  ON dd_answer.full_date = r.review_answer_ts::date;
  

----------------------------------------------
--  fact_order_reviews - Quality checks     --
----------------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_reviews' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM dwh.fact_order_reviews;

-- Perte de lignes entre stg.order_reviews et dwh.fact_order_reviews
--------------------------------------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_reviews' AS table_name,
  'missing_rows_vs_stg' AS check_name,
  (
    (SELECT COUNT(*) FROM stg.order_reviews)
    - (SELECT COUNT(*) FROM dwh.fact_order_reviews)
  ) AS row_count,
  CASE
    WHEN (
      (SELECT COUNT(*) FROM stg.order_reviews)
      - (SELECT COUNT(*) FROM dwh.fact_order_reviews)
    ) = 0
    THEN 'OK'
    ELSE 'WARN'
  END AS status;

-- review_score hors bornes
---------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'dwh' AS layer,
  'fact_order_reviews' AS table_name,
  'invalid_review_score' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM dwh.fact_order_reviews
WHERE review_score IS NOT NULL
  AND (review_score < 1 OR review_score > 5);

  