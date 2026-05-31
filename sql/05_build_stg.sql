-----------------------------
-- Création des tables STG --
-----------------------------

-----------------------------
--         orders          --
-----------------------------
DROP TABLE IF EXISTS stg.orders;
-- on déclare bien explicitement tous les types
-- au cas où la source changerait à l'avenir
CREATE TABLE stg.orders (
	-- PRIMARY KEY impose automatiquement NOT NULL
    order_id TEXT PRIMARY KEY,
    customer_id TEXT NOT NULL,
    order_status TEXT,
    purchase_ts TIMESTAMP,
    approved_ts TIMESTAMP,
    delivered_carrier_ts TIMESTAMP,
    delivered_customer_ts TIMESTAMP,
    estimated_delivery_ts TIMESTAMP,
	-- On va créer des métriques ici directement
	-- La soustraction retournera un int puisqu'on va caster en date
	lead_time_days INT,
	shipping_duration_days INT,
	delivery_delay_days INT,

	-- On ajoute un garde-fou automatique
	-- pour ne pas avoir de lead_time_days négatif.
	-- Les lead_time_days négatifs sont normalement traités
	-- plus bas, mais on se protège contre des modifs futures.
	CONSTRAINT chk_lead_time_positive
	CHECK (lead_time_days IS NULL OR lead_time_days >= 0)	
);

INSERT INTO stg.orders
SELECT
	order_id,
	customer_id,
	order_status,
	-- On caste les dates proprement en gérant les champs vides.
	NULLIF(order_purchase_timestamp, '')::timestamp,
	NULLIF(order_approved_at, '')::timestamp,
	NULLIF(order_delivered_carrier_date, '')::timestamp,
	NULLIF(order_delivered_customer_date, '')::timestamp,
	NULLIF(order_estimated_delivery_date, '')::timestamp,

	-- Création des métriques : 

	-- lead_time_days : Commande -> Livraison
	CASE
	  WHEN NULLIF(order_delivered_customer_date, '') IS NULL
	    OR NULLIF(order_purchase_timestamp, '') IS NULL
	  THEN NULL
	  ELSE
	  	-- On traite les valeurs négatives.
	    CASE
	      WHEN (
	        NULLIF(order_delivered_customer_date, '')::date
	        - NULLIF(order_purchase_timestamp, '')::date
	      ) < 0
	      THEN NULL
	      ELSE (
	        NULLIF(order_delivered_customer_date, '')::date
	        - NULLIF(order_purchase_timestamp, '')::date
	      )
	    END
	END,
	
	-- shipping_duration_days : Expédition -> Livraison
	CASE
	  WHEN NULLIF(order_delivered_customer_date, '') IS NULL
	       OR NULLIF(order_delivered_carrier_date, '') IS NULL
	  THEN NULL
	  ELSE
	    CASE
		  -- On gère ici les cas de valeurs négatives (anomalies de dates)
	      WHEN (
	        NULLIF(order_delivered_customer_date, '')::date
	        - NULLIF(order_delivered_carrier_date, '')::date
	      ) < 0
	      THEN NULL
	      ELSE (
	        NULLIF(order_delivered_customer_date, '')::date
	        - NULLIF(order_delivered_carrier_date, '')::date
	      )
	    END
	END,
	
	-- delivery_delay_days : retard par rapport à la date de livraison annoncée
	-- On va garder les négatifs, ça nous permettra de voir si on a tendance
	-- à surestimer le délai de livraison.
	CASE
	WHEN NULLIF(order_delivered_customer_date, '') IS NULL
		 OR NULLIF(order_estimated_delivery_date, '') IS NULL
	THEN NULL
	ELSE (
	  NULLIF(order_delivered_customer_date, '')::date
	  - NULLIF(order_estimated_delivery_date, '')::date
	)
	END

FROM raw.orders;

----------------------------------------
--      orders - Quality checks       --
----------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
-- Contrairement au rows_loaded check au layer raw, on test pour chaque table
-- séparément, pour voir où ça bloque vu qu'on a des contraintes (PK, NOT NULL...)
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  -- On ne renseigne pas run_ts, on laisse le default faire son travail
  'stg' AS layer,
  'orders' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.orders;


-- Cohérence temporelle basique : 
---------------------------------

-- approved avant purchase
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'approved_before_purchase' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.orders
WHERE approved_ts IS NOT NULL
  AND purchase_ts IS NOT NULL
  AND approved_ts < purchase_ts;

-- carrier avant purchase
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'carrier_before_purchase' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.orders
WHERE delivered_carrier_ts IS NOT NULL
  AND purchase_ts IS NOT NULL
  AND delivered_carrier_ts < purchase_ts;

-- delivered avant carrier : on a déjà nettoyé la durée négative
-- sur shipping_duration_days, mais on trace la source pour monitorer
-- l'évolution de ce type d'anomalie.
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'delivered_before_carrier' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.orders
WHERE delivered_customer_ts IS NOT NULL
  AND delivered_carrier_ts IS NOT NULL
  AND delivered_customer_ts < delivered_carrier_ts;

-- Détecter des outliers sur lead_time_days
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'lead_time_over_365' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.orders
WHERE lead_time_days > 365;

-- Référentiel minimal (FK logique) :
-------------------------------------
-- On va vérifier que chaque order a un customer existant
-- dans raw.customers car stg.customers n'existe pas encore à ce stade.
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'missing_customer_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.orders o
LEFT JOIN raw.customers c
  ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;

-- orders qui pointent vers un customer_id inexistant
--------------------------------------
-- Je mettrai cette partie après la création de la table customers



-----------------------------
--       order_items       --
-----------------------------
-- C’est la table qui va devenir notre future fact table,
-- grain = ligne de commande (1 ligne = 1 produit dans 1 commande)
DROP TABLE IF EXISTS stg.order_items;
-- on déclare bien explicitement tous les types
-- au cas où la source changerait à l'avenir
CREATE TABLE stg.order_items (
	-- order_id seul ne peut pas être la PK
	-- car plusieurs lignes peuvent avoir le même order_id
	-- (commande avec plusieurs articles). Donc on fera une
	-- PK composite avec order_item_id sous forme de contrainte.
	-- NOT NULL sera imposé par PK dans contrainte,
	-- mais je garde pour lisibilité.
    order_id TEXT NOT NULL,
    order_item_id INT NOT NULL,
    product_id TEXT,
    seller_id TEXT,
    shipping_limit_ts TIMESTAMP,
	-- NUMERIC(12,2) : nombre décimal exact,
	-- 12 chiffres max, 2 décimales.
    price NUMERIC(12,2) NOT NULL,
    freight_value NUMERIC(12,2) NOT NULL,

	-- Définition de la PK composite via une contrainte.
    CONSTRAINT pk_stg_order_items PRIMARY KEY (order_id, order_item_id),

    -- garde-fous simples

    CONSTRAINT chk_price_non_negative CHECK (price >= 0),
    CONSTRAINT chk_freight_non_negative CHECK (freight_value >= 0)
);

INSERT INTO stg.order_items
SELECT
    order_id,
	-- NULLIF() sinon le cast fera une erreur si ''.
	-- Le NULL éventuel bloquera l'INSERT car NOT NULL sur order_item_id,
	-- mais au moins l'erreur sera plus simple à interpréter.
	-- TRIM() pour gérer les éventuels '  '
    NULLIF(TRIM(order_item_id), '')::int,
    product_id,
    seller_id,
    NULLIF(TRIM(shipping_limit_date), '')::timestamp,
	-- Même logique ici
    NULLIF(TRIM(price), '')::numeric(12,2),
    NULLIF(TRIM(freight_value), '')::numeric(12,2)
FROM raw.order_items;

----------------------------------------
--    order_items - Quality checks    --
----------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_items' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_items;

-- order_id existe dans stg.orders
-- c'est important pour la suite.
----------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_items' AS table_name,
  'missing_order_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_items oi
LEFT JOIN stg.orders o
  ON o.order_id = oi.order_id
WHERE o.order_id IS NULL;
-- On pourrait remplacer par une contrainte FOREIGN KEY (order_id) REFERENCES stg.orders(order_id)
-- mais je décide pour l'instant logger l'anomalie plutôt que de bloquer le pipeline.

-- Pas de product_id ou de seller_id
-- pas forcément bloquant mais c'est mieux de logger.
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_items' AS table_name,
  'null_product_or_seller' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.order_items
WHERE product_id IS NULL OR seller_id IS NULL;

-- order_items qui pointent vers un product_id inexistant
--------------------------------------
-- Je mettrai cette partie après la création de la table products

-- order_items qui pointent vers un seller_id inexistant
--------------------------------------
-- Je mettrai cette partie après la création de la table sellers



---------------------------
--       customers       --
---------------------------
DROP TABLE IF EXISTS stg.customers;
-- On déclare bien explicitement tous les types
-- au cas où la source changerait à l'avenir.
-- customer_id = identifiant technique (utilisé dans les commandes) donc PK
-- customer_unique_id = identifiant client "réel" (même personne sur plusieurs commandes)
-- Donc dans stg.customers, on garde les deux, mais notre dimension client future
-- devra probablement être basée sur customer_unique_id
CREATE TABLE stg.customers (
    customer_id TEXT PRIMARY KEY,
    customer_unique_id TEXT NOT NULL,
    customer_zip_code_prefix TEXT,
    customer_city TEXT,
    customer_state TEXT
);
INSERT INTO stg.customers
SELECT
    customer_id,
	-- TRIM() pour gérer les éventuels '  '
	NULLIF(TRIM(customer_unique_id), ''),
    customer_zip_code_prefix,
	NULLIF(TRIM(customer_city), ''),
	NULLIF(TRIM(customer_state), '')
FROM raw.customers;

--------------------------------------
--    customers - Quality checks    --
--------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'customers' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.customers;

-- orders qui pointent vers un customer_id inexistant
--------------------------------------
-- C'est un check pour la table orders mais on devait
-- attendre que la table customers soit crée.
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'orders' AS table_name,
  'missing_customer_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.orders o
LEFT JOIN stg.customers c
  ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;



---------------------------
--       products        --
---------------------------
DROP TABLE IF EXISTS stg.products;
CREATE TABLE stg.products (
    product_id TEXT PRIMARY KEY,
    product_category_name TEXT,
    product_name_lenght INT,
    product_description_lenght INT,
    product_photos_qty INT,
    product_weight_g INT,
    product_length_cm INT,
    product_height_cm INT,
    product_width_cm INT
);
INSERT INTO stg.products
SELECT
    product_id,
    NULLIF(TRIM(product_category_name), ''),
    NULLIF(TRIM(product_name_lenght), '')::int,
    NULLIF(TRIM(product_description_lenght), '')::int,
	-- On va nettoyer les valeurs aberrantes (négatives ou 0).
	-- Pas la peine de bloquer le pipeline avec des contraintes pour ces valeurs.
    CASE
      WHEN NULLIF(TRIM(product_photos_qty), '')::int < 0  -- ici 0 n'est pas aberrant
      THEN NULL
      ELSE NULLIF(TRIM(product_photos_qty), '')::int
    END,

    CASE
      WHEN NULLIF(TRIM(product_weight_g), '')::int <= 0
      THEN NULL
      ELSE NULLIF(TRIM(product_weight_g), '')::int
    END,

    CASE
      WHEN NULLIF(TRIM(product_length_cm), '')::int <= 0
      THEN NULL
      ELSE NULLIF(TRIM(product_length_cm), '')::int
    END,

    CASE
      WHEN NULLIF(TRIM(product_height_cm), '')::int <= 0
      THEN NULL
      ELSE NULLIF(TRIM(product_height_cm), '')::int
    END,

    CASE
      WHEN NULLIF(TRIM(product_width_cm), '')::int <= 0
      THEN NULL
      ELSE NULLIF(TRIM(product_width_cm), '')::int
    END
FROM raw.products;

--------------------------------------
--    products - Quality checks     --
--------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
	'stg' AS layer,
	'products' AS table_name,
	'rows_loaded' AS check_name,
	COUNT(*) AS row_count,
	CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.products;

-- order_items qui pointent vers un product_id inexistant
--------------------------------------
-- C'est un check pour la table order_items mais on devait
-- attendre que la table products soit créée.
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
	'stg' AS layer,
	'order_items' AS table_name,
	'missing_product_reference' AS check_name,
	COUNT(*) AS row_count,
	CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_items oi
LEFT JOIN stg.products p
  ON p.product_id = oi.product_id
WHERE p.product_id IS NULL
  AND oi.product_id IS NOT NULL;  -- comme ça ce check ne compte que les "orphelins" réels



---------------------------
--        sellers        --
---------------------------
DROP TABLE IF EXISTS stg.sellers;

CREATE TABLE stg.sellers (
    seller_id TEXT PRIMARY KEY,
    seller_zip_code_prefix TEXT,
    seller_city TEXT,
    seller_state TEXT
);

INSERT INTO stg.sellers
SELECT
    seller_id,
    NULLIF(TRIM(seller_zip_code_prefix), ''),
    NULLIF(TRIM(seller_city), ''),
    NULLIF(TRIM(seller_state), '')
FROM raw.sellers;

--------------------------------------
--     sellers - Quality checks     --
--------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'sellers' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.sellers;

-- order_items qui pointent vers un seller_id inexistant (orphelins réels)
--------------------------------------
-- C'est un check pour la table order_items mais on devait
-- attendre que la table sellers soit créée.
-- (on exclut seller_id NULL, qui est un autre problème déjà mesurable)
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_items' AS table_name,
  'missing_seller_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_items oi
LEFT JOIN stg.sellers s
  ON s.seller_id = oi.seller_id
WHERE s.seller_id IS NULL
  AND oi.seller_id IS NOT NULL;  -- comme ça ce check ne compte que les "orphelins" réels




------------------------------
--      order_payments      --
------------------------------
-- Le grain natif de cette table est :
-- 1 ligne = 1 enregistrement de paiement pour 1 commande.
-- Donc une commande peut apparaître plusieurs fois,
-- donc pas de PK sur order_id, on fera PK composite via contrainte.
-- On garde ce grain en stg. On n’agrège pas encore.
DROP TABLE IF EXISTS stg.order_payments;

CREATE TABLE stg.order_payments (
    -- NOT NULL sera imposé par PK dans contrainte,
	-- mais je garde pour lisibilité.
    order_id TEXT NOT NULL,
    payment_sequential INT NOT NULL,
    payment_type TEXT,
    payment_installments INT,
	-- NOT NULL sur payment_value : mesure centrale, si manquant la ligne
	-- devient presque inutilisable. Si vide, l’INSERT doit échouer
    payment_value NUMERIC(12,2) NOT NULL,

    -- PK composite selon grain natif : 1 ligne = 1 enregistrement de paiement pour 1 commande
    CONSTRAINT pk_stg_order_payments PRIMARY KEY (order_id, payment_sequential)
);

INSERT INTO stg.order_payments
SELECT
    order_id,
    NULLIF(TRIM(payment_sequential), '')::int,
    NULLIF(TRIM(payment_type), ''),
    
    CASE
	  -- <= 0 est aberrant mais pas bloquant, donc null acceptable
      WHEN NULLIF(TRIM(payment_installments), '')::int <= 0
      THEN NULL
      ELSE NULLIF(TRIM(payment_installments), '')::int
    END,

    NULLIF(TRIM(payment_value), '')::numeric(12,2)
FROM raw.order_payments;

---------------------------------------
--  order_payments - Quality checks  --
---------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_payments' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_payments;

-- Référence manquante vers orders
----------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_payments' AS table_name,
  'missing_order_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_payments p
LEFT JOIN stg.orders o
  ON o.order_id = p.order_id
WHERE o.order_id IS NULL
  AND p.order_id IS NOT NULL;

-- Pas de type de paiement ?
----------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_payments' AS table_name,
  'null_payment_type' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.order_payments
WHERE payment_type IS NULL;



-----------------------------
--      order_reviews      --
-----------------------------
-- Attention, review_id a des doublons,
-- donc pas possible de PK simple dessus.
-- On fera donc une PK composite en contrainte.
-- Grain : 1 ligne = 1 review pour 1 commande
-- défini après contrôle d’unicité sur (review_id, order_id)
DROP TABLE IF EXISTS stg.order_reviews;

CREATE TABLE stg.order_reviews (
    review_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    review_score INT,
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_ts TIMESTAMP,
    review_answer_ts TIMESTAMP,

    CONSTRAINT pk_stg_order_reviews PRIMARY KEY (review_id, order_id)
);

INSERT INTO stg.order_reviews
SELECT
    review_id,
    order_id,
    NULLIF(TRIM(review_score), '')::int,
    NULLIF(TRIM(review_comment_title), ''),
    NULLIF(TRIM(review_comment_message), ''),
    NULLIF(TRIM(review_creation_date), '')::timestamp,
    NULLIF(TRIM(review_answer_timestamp), '')::timestamp
FROM raw.order_reviews;

---------------------------------------
--   order_reviews - Quality checks  --
---------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_reviews' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_reviews;

-- Référence manquante vers orders
----------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_reviews' AS table_name,
  'missing_order_reference' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.order_reviews r
LEFT JOIN stg.orders o
  ON o.order_id = r.order_id
WHERE o.order_id IS NULL;

-- review_score hors bornes
---------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_reviews' AS table_name,
  'invalid_review_score' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.order_reviews
WHERE review_score IS NOT NULL
  AND (review_score < 1 OR review_score > 5);

-- Réponse avant création de la review
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'order_reviews' AS table_name,
  'answer_before_creation' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.order_reviews
WHERE review_answer_ts IS NOT NULL
  AND review_creation_ts IS NOT NULL
  AND review_answer_ts < review_creation_ts;



-----------------------------------------
--  product_category_name_translation  --
-----------------------------------------
DROP TABLE IF EXISTS stg.product_category_name_translation;

CREATE TABLE stg.product_category_name_translation (
    product_category_name TEXT PRIMARY KEY,
    product_category_name_english TEXT
);

INSERT INTO stg.product_category_name_translation
SELECT
    NULLIF(TRIM(product_category_name), ''),
    NULLIF(TRIM(product_category_name_english), '')
FROM raw.product_category_name_translation;

-----------------------------------------------------------
--   product_category_name_translation - Quality checks  --
-----------------------------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'product_category_name_translation' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.product_category_name_translation;

-- Traduction manquante ?
-------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'product_category_name_translation' AS table_name,
  'null_translation' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.product_category_name_translation
WHERE product_category_name_english IS NULL;



---------------------------
--      geolocation      --
---------------------------
-- Cette table est volumineuse et contient beaucoup de doublons.
-- geolocation_zip_code_prefix n’est pas unique.
-- Pour un même zip prefix, on peut avoir plusieurs lat/lng.
-- Pour l'instant on charge tout et pour le DWH, on fera une version agrégée.
DROP TABLE IF EXISTS stg.geolocation;

CREATE TABLE stg.geolocation (
    geolocation_zip_code_prefix TEXT,
	-- Pas la peine d'avoir plus de 7 décimales,
	-- c'est déjà assez précis.
    geolocation_lat NUMERIC(10,7),
    geolocation_lng NUMERIC(10,7),
    geolocation_city TEXT,
    geolocation_state TEXT
);

INSERT INTO stg.geolocation
SELECT
    NULLIF(TRIM(geolocation_zip_code_prefix), ''),
    NULLIF(TRIM(geolocation_lat), '')::numeric(10,7),
    NULLIF(TRIM(geolocation_lng), '')::numeric(10,7),
    NULLIF(TRIM(geolocation_city), ''),
    NULLIF(TRIM(geolocation_state), '')
FROM raw.geolocation;

------------------------------------
--  geolocation - Quality checks  --
------------------------------------

-- Des lignes ont-elles été chargées ?
--------------------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'geolocation' AS table_name,
  'rows_loaded' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'FAIL' END AS status
FROM stg.geolocation;

-- Coordonnées manquantes
-------------------------
INSERT INTO dq.check_results (layer, table_name, check_name, row_count, status)
SELECT
  'stg' AS layer,
  'geolocation' AS table_name,
  'null_lat_or_lng' AS check_name,
  COUNT(*) AS row_count,
  CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'WARN' END AS status
FROM stg.geolocation
WHERE geolocation_lat IS NULL
   OR geolocation_lng IS NULL;