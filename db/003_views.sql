-- ============================================================================
-- Представления: витрина сайта, наследование атрибутов категории, метрики
-- ============================================================================
BEGIN;
SET search_path TO onmi, public;

-- Действующий состав атрибутов категории: собственный + унаследованный от предков
CREATE OR REPLACE VIEW v_category_effective_attribute AS
WITH RECURSIVE tree AS (
    SELECT category_id, parent_id FROM category
    WHERE category_id IN (SELECT DISTINCT category_id FROM category_attribute)
    UNION ALL
    SELECT c.category_id, c.parent_id FROM category c JOIN tree t ON c.category_id = t.parent_id
)
SELECT DISTINCT
    ca.category_id, ca.attribute_id, a.code AS attribute_code, ca.role
FROM category_attribute ca
JOIN attribute a USING (attribute_id)
WHERE ca.category_id IN (SELECT category_id FROM tree);

-- Витрина: одна активная цена на (карточка x склад x поставщик)
CREATE OR REPLACE VIEW v_site_price AS
SELECT DISTINCT ON (cl.product_id, op.warehouse_id, o.supplier_id)
    cl.product_id,
    p.slug,
    o.supplier_id,
    o.offer_id,
    sw.external_name AS warehouse_name,
    op.price_vat,
    op.price_no_vat,
    u.code           AS unit_code,
    op.price_date,
    op.valid_from    AS price_valid_from
FROM card_link cl
JOIN product p   ON p.product_id = cl.product_id
JOIN offer o     ON o.offer_id = cl.offer_id AND o.status = 'active'
JOIN offer_price op ON op.offer_id = o.offer_id AND op.valid_to IS NULL
JOIN supplier_warehouse sw ON sw.warehouse_id = op.warehouse_id
JOIN unit u      ON u.unit_id = op.unit_id
JOIN condition_policy cp ON cp.condition_code = o.condition AND cp.action = 'show'
WHERE cl.status = 'active'
  AND op.price_date >= current_date - COALESCE(
        (SELECT (value ->> 'days')::int FROM config WHERE config_key = 'freshness_days'), 60)
ORDER BY cl.product_id, op.warehouse_id, o.supplier_id, op.valid_from DESC;
COMMENT ON VIEW v_site_price IS 'Цены для сайта: активные привязки x активные цены x свежесть x политика состояний';

-- Метрики привязки по последнему прогону матчинга каждого прайса
CREATE OR REPLACE VIEW v_match_metrics AS
WITH last_runs AS (
    SELECT DISTINCT ON (price_list_id) price_list_id, run_id, finished_at, stats
    FROM pipeline_run
    WHERE job_type = 'match' AND price_list_id IS NOT NULL
    ORDER BY price_list_id, finished_at DESC
)
SELECT
    pl.supplier_id,
    pl.price_list_id,
    lr.finished_at,
    lr.stats ->> 'rows_total'   AS rows_total,
    lr.stats ->> 'linked'       AS linked,
    lr.stats ->> 'review'       AS review,
    lr.stats ->> 'rejected'     AS rejected,
    lr.stats ->> 'ignored'      AS ignored,
    round(100.0 * NULLIF(lr.stats ->> 'linked','')::numeric
          / NULLIF(lr.stats ->> 'rows_total','')::numeric, 1) AS linked_pct
FROM last_runs lr
JOIN price_list pl USING (price_list_id);

-- Текущее покрытие каталога активными предложениями
CREATE OR REPLACE VIEW v_catalog_coverage AS
SELECT c.path AS category_path,
       count(DISTINCT p.product_id) AS cards,
       count(DISTINCT cl.product_id) AS cards_with_active_offer
FROM product p
JOIN category c USING (category_id)
LEFT JOIN card_link cl ON cl.product_id = p.product_id AND cl.status = 'active'
WHERE p.work_status <> 'archived'
GROUP BY c.path
ORDER BY c.path;

-- Открытые проблемы качества (block/warn) и очередь ручного разбора
CREATE OR REPLACE VIEW v_open_problems AS
SELECT r.severity, r.code AS rule_code, vr.entity_type, vr.entity_id, vr.detected_at, vr.details
FROM validation_result vr
JOIN validation_rule r USING (rule_id)
WHERE vr.status = 'open'
ORDER BY r.severity, vr.detected_at;

CREATE OR REPLACE VIEW v_review_queue AS
SELECT t.task_id, t.subject_type, t.subject_id, t.reason_code, t.priority, t.created_at,
       t.payload, t.assigned_to
FROM review_task t
WHERE t.status IN ('open', 'claimed')
ORDER BY t.priority, t.created_at;

COMMIT;
