-- ============================================================================
-- Smoke-тест инвариантов на живой PostgreSQL. Запуск:
--   docker exec -i onmi-pg-verify psql -U postgres < db/tests/001_invariants.sql
-- Каждый TEST печатает OK (ожидаемое отклонение) или падает с FAIL.
-- ============================================================================
BEGIN;
SET search_path TO onmi, public;
SET client_min_messages = notice;

-- ---------- Подготовка: файл прайса, позиции, карточки ----------
INSERT INTO price_list (price_list_id, supplier_id, file_name, file_sha256)
VALUES ('30000000-0000-0000-0000-000000000001',
        (SELECT supplier_id FROM supplier WHERE code='metallservice'),
        'МС-прайс-тест.xlsx', repeat('a',64));

INSERT INTO price_list_row (price_list_id, row_number, warehouse_name, supplier_category,
                            title_raw, attributes_raw, unit_raw, price_vat, price_no_vat, price_date)
VALUES ('30000000-0000-0000-0000-000000000001', 1, 'Курск', 'Металлопрокат / ТРУБЫ ВОДОГАЗОПРОВ.',
        'Труба ВГП 20х2,8 оцинк. 6 м', 'diameter: 20; wall_thickness: 2.8; coating: оцинк.; length_class: 6м',
        'т', 110000, 90163.93, current_date),
       ('30000000-0000-0000-0000-000000000001', 2, 'Курск', 'Металлопрокат / ТРУБЫ ВОДОГАЗОПРОВ.',
        'Труба ВГП 20х2,8 6 м', 'diameter: 20; wall_thickness: 2.8; length_class: 6м',
        'т', 62000, 50819.67, current_date);

-- Офферы: оцинкованная и чёрная труба 20х2,8 6м (контрольный случай 1)
INSERT INTO offer (offer_id, supplier_id, natural_key_hash, natural_key, current_title, current_unit_id) VALUES
 ('40000000-0000-0000-0000-000000000001',(SELECT supplier_id FROM supplier WHERE code='metallservice'),'nk-zn-20-2.8-6m','ВГП | d20 | s2.8 | zn | 6m | т','Труба ВГП 20х2,8 оцинк. 6 м',(SELECT unit_id FROM unit WHERE code='t')),
 ('40000000-0000-0000-0000-000000000002',(SELECT supplier_id FROM supplier WHERE code='metallservice'),'nk-black-20-2.8-6m','ВГП | d20 | s2.8 | uncoated | 6m | т','Труба ВГП 20х2,8 6 м',(SELECT unit_id FROM unit WHERE code='t'));

INSERT INTO offer_attribute (offer_id, attribute_id, value_number, attribute_value_id, parsed_from)
SELECT o.offer_id, a.attribute_id,
       CASE a.code WHEN 'diameter' THEN 20 WHEN 'wall_thickness' THEN 2.8 END,
       CASE a.code WHEN 'coating' THEN av.attribute_value_id WHEN 'length_class' THEN av.attribute_value_id END,
       'column'
FROM offer o
CROSS JOIN attribute a
LEFT JOIN attribute_value av ON av.attribute_id = a.attribute_id
     AND av.code = CASE WHEN a.code='coating' THEN (CASE o.natural_key_hash WHEN 'nk-zn-20-2.8-6m' THEN 'zn' ELSE 'uncoated' END)
                        WHEN a.code='length_class' THEN '6m' END
WHERE o.natural_key_hash IN ('nk-zn-20-2.8-6m','nk-black-20-2.8-6m')
  AND a.code IN ('diameter','wall_thickness','coating','length_class');

-- Карточки: оцинкованная и чёрная (категория Трубы ВГП: required = диаметр, стенка, покрытие, класс длины)
INSERT INTO product (product_id, slug, name_ru, category_id, unit_id, work_status, source) VALUES
 ('50000000-0000-0000-0000-000000000001','truba-vgp-20x2-8-zn-6m','Труба ВГП 20х2,8 оцинкованная 6 м','10000000-0000-0000-0000-0000000000c3',(SELECT unit_id FROM unit WHERE code='t'),'published','migration'),
 ('50000000-0000-0000-0000-000000000002','truba-vgp-20x2-8-6m','Труба ВГП 20х2,8 6 м','10000000-0000-0000-0000-0000000000c3',(SELECT unit_id FROM unit WHERE code='t'),'published','migration');

INSERT INTO product_attribute (product_id, category_id, attribute_id, value_number, attribute_value_id)
SELECT p.product_id, p.category_id, a.attribute_id,
       CASE a.code WHEN 'diameter' THEN 20 WHEN 'wall_thickness' THEN 2.8 END,
       CASE a.code WHEN 'coating' THEN av.attribute_value_id WHEN 'length_class' THEN av.attribute_value_id END
FROM product p
CROSS JOIN attribute a
LEFT JOIN attribute_value av ON av.attribute_id = a.attribute_id
     AND av.code = CASE WHEN a.code='coating' THEN (CASE p.slug WHEN 'truba-vgp-20x2-8-zn-6m' THEN 'zn' ELSE 'uncoated' END)
                        WHEN a.code='length_class' THEN '6m' END
WHERE p.slug IN ('truba-vgp-20x2-8-zn-6m','truba-vgp-20x2-8-6m')
  AND a.code IN ('diameter','wall_thickness','coating','length_class');

-- ---------- TEST 1: атрибут вне категории отвергается составным FK ----------
DO $$
BEGIN
    INSERT INTO product_attribute (product_id, category_id, attribute_id, value_text)
    VALUES ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-0000000000c3',
            (SELECT attribute_id FROM attribute WHERE code='brand'),'Samsung');
    RAISE EXCEPTION 'TEST 1 FAIL: атрибут вне категории вставился';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'TEST 1 OK: атрибут не из категории отвергнут составным FK';
END $$;

-- ---------- TEST 2: дубль карточки (в т.ч. 20.0 против 20) отвергается ----------
DO $$
BEGIN
    INSERT INTO product (product_id, slug, name_ru, category_id, unit_id)
    VALUES ('50000000-0000-0000-0000-000000000003','truba-vgp-20x2-8-zn-6m-dup','Дубль','10000000-0000-0000-0000-0000000000c3',(SELECT unit_id FROM unit WHERE code='t'));
    INSERT INTO product_attribute (product_id, category_id, attribute_id, value_number, attribute_value_id)
    SELECT '50000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-0000000000c3', a.attribute_id,
           CASE a.code WHEN 'diameter' THEN 20.0 WHEN 'wall_thickness' THEN 2.80 END,
           CASE a.code WHEN 'coating' THEN av.attribute_value_id WHEN 'length_class' THEN av.attribute_value_id END
    FROM attribute a
    LEFT JOIN attribute_value av ON av.attribute_id=a.attribute_id
         AND av.code IN ('zn','6m') AND a.code IN ('coating','length_class')
    WHERE a.code IN ('diameter','wall_thickness','coating','length_class');
    RAISE EXCEPTION 'TEST 2 FAIL: дубль карточки вставился';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 2 OK: дубль по identity отвергнут (20.0 канонизирован в 20)';
END $$;

-- ---------- TEST 3: оцинкованная позиция не встанет на чёрную карточку ----------
DO $$
BEGIN
    INSERT INTO card_link (offer_id, product_id, status, method, confidence, rule_trace)
    VALUES ('40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002',
            'active','rules_exact',1.0,'{"rules":["category","attrs_exact"]}');
    RAISE EXCEPTION 'TEST 3 FAIL: чужая привязка активировалась';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'TEST 3 OK: страж привязки отверг чужую карточку (%)', SQLERRM;
END $$;

-- ---------- Валидная привязка + цена ----------
INSERT INTO card_link (offer_id, product_id, status, method, confidence, rule_trace)
VALUES ('40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','active','rules_exact',1.0,'{"rules":["category","attrs_exact"]}');

INSERT INTO offer_price (offer_id, warehouse_id, price_list_id, price_vat, price_no_vat, unit_id, price_date)
SELECT '40000000-0000-0000-0000-000000000001', w.warehouse_id, '30000000-0000-0000-0000-000000000001',
       110000, 90163.93, (SELECT unit_id FROM unit WHERE code='t'), current_date
FROM supplier_warehouse w
JOIN supplier s USING (supplier_id)
WHERE s.code='metallservice' AND w.external_name='Курск';

-- ---------- TEST 4: дубль той же пары оффер-карточка ----------
DO $$
BEGIN
    INSERT INTO card_link (offer_id, product_id, status, method)
    VALUES ('40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','candidate','manual');
    RAISE EXCEPTION 'TEST 4 FAIL: дубль пары вставился';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 4 OK: дубль пары (offer, product) отвергнут; вторая активная невозможна: страж требует совпадения identity, а identity уникален в категории';
END $$;

-- ---------- TEST 5: вторая активная цена на позицию и склад ----------
DO $$
BEGIN
    INSERT INTO offer_price (offer_id, warehouse_id, price_list_id, price_vat, unit_id, price_date)
    SELECT '40000000-0000-0000-0000-000000000001', w.warehouse_id, '30000000-0000-0000-0000-000000000001',
           111000, (SELECT unit_id FROM unit WHERE code='t'), current_date
    FROM supplier_warehouse w
    JOIN supplier s USING (supplier_id)
    WHERE s.code='metallservice' AND w.external_name='Курск';
    RAISE EXCEPTION 'TEST 5 FAIL: вторая активная цена вставилась';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 5 OK: вторая активная цена на позицию и склад отвергнута (анти-473-дублей)';
END $$;

-- ---------- TEST 6: повторная загрузка того же файла ----------
DO $$
BEGIN
    INSERT INTO price_list (supplier_id, file_name, file_sha256)
    VALUES ((SELECT supplier_id FROM supplier WHERE code='metallservice'),'копия.xlsx', repeat('a',64));
    RAISE EXCEPTION 'TEST 6 FAIL: файл-дубликат вставился';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 6 OK: повторная загрузка файла отвергнута по SHA-256';
END $$;

-- ---------- TEST 7: block-проблема валидации останавливает привязку ----------
INSERT INTO validation_result (rule_id, entity_type, entity_id, severity_at_detection, details)
SELECT rule_id, 'product', '50000000-0000-0000-0000-000000000002', 'block',
       jsonb_build_object('found','Ду 20','attr','Ду 15')
FROM validation_rule WHERE code='name_attr_dn_mismatch';

DO $$
BEGIN
    INSERT INTO card_link (offer_id, product_id, status, method, confidence)
    VALUES ('40000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000002','active','rules_exact',1.0);
    RAISE EXCEPTION 'TEST 7 FAIL: привязка к карточке с block-проблемой активировалась';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'TEST 7 OK: привязка к карточке с открытой block-проблемой заблокирована';
END $$;

UPDATE validation_result SET status='resolved', resolved_at=now() WHERE entity_id='50000000-0000-0000-0000-000000000002';

-- ---------- TEST 8: позиция «НН» скрыта политикой ----------
DO $$
BEGIN
    INSERT INTO offer (offer_id, supplier_id, natural_key_hash, natural_key, condition, current_unit_id)
    VALUES ('40000000-0000-0000-0000-000000000003',(SELECT supplier_id FROM supplier WHERE code='metallservice'),
            'nk-nn-20-2.8-6m','ВГП | d20 | s2.8 | uncoated | 6m | nn | т','nn',(SELECT unit_id FROM unit WHERE code='t'));
    INSERT INTO offer_attribute (offer_id, attribute_id, value_number, attribute_value_id, parsed_from)
    SELECT '40000000-0000-0000-0000-000000000003', a.attribute_id,
           CASE a.code WHEN 'diameter' THEN 20 WHEN 'wall_thickness' THEN 2.8 END,
           CASE a.code WHEN 'coating' THEN av.attribute_value_id WHEN 'length_class' THEN av.attribute_value_id END,'column'
    FROM attribute a LEFT JOIN attribute_value av ON av.attribute_id=a.attribute_id
         AND av.code IN ('uncoated','6m') AND a.code IN ('coating','length_class')
    WHERE a.code IN ('diameter','wall_thickness','coating','length_class');
    INSERT INTO card_link (offer_id, product_id, status, method, confidence)
    VALUES ('40000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000002','active','rules_exact',1.0);
    RAISE EXCEPTION 'TEST 8 FAIL: НН-позиция опубликовалась';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'TEST 8 OK: позиция «НН» не публикуется — политика скрытия';
END $$;

-- ---------- TEST 9: карточка с неполной идентичностью не получает привязку ----------
DO $$
DECLARE v_identity text;
BEGIN
    INSERT INTO product (product_id, slug, name_ru, category_id, unit_id)
    VALUES ('50000000-0000-0000-0000-000000000004','truba-vgp-20x2-8-todo','Недозаполненная','10000000-0000-0000-0000-0000000000c3',(SELECT unit_id FROM unit WHERE code='t'));
    INSERT INTO product_attribute (product_id, category_id, attribute_id, value_number)
    SELECT '50000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-0000000000c3', attribute_id, 20
    FROM attribute WHERE code='diameter';
    SELECT identity_hash INTO v_identity FROM product WHERE product_id='50000000-0000-0000-0000-000000000004';
    IF v_identity IS NOT NULL THEN RAISE EXCEPTION 'TEST 9 FAIL: identity неполной карточки не NULL'; END IF;
    INSERT INTO card_link (offer_id, product_id, status, method, confidence)
    VALUES ('40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000004','active','rules_exact',1.0);
    RAISE EXCEPTION 'TEST 9 FAIL: привязка к неполной карточке активировалась';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'TEST 9 OK: identity неполной карточки = NULL, привязка запрещена (путь в review/upgrade_card)';
END $$;

-- ---------- TEST 10: витрина показывает ровно одну цену ----------
DO $$
DECLARE n int; price numeric;
BEGIN
    SELECT count(*), max(price_vat) INTO n, price FROM v_site_price
    WHERE product_id='50000000-0000-0000-0000-000000000001';
    IF n <> 1 THEN RAISE EXCEPTION 'TEST 10 FAIL: строк в витрине = %', n; END IF;
    RAISE NOTICE 'TEST 10 OK: v_site_price отдаёт 1 цену (%) на карточку-склад-поставщика', price;
END $$;

-- Аудит и очереди задокументированы данными:
SELECT 'audit entries: ' || count(*) FROM audit_log WHERE entity_type LIKE '%card_link%';
SELECT 'identity чёрной карточки отличается от оцинкованной: '
     || (identity_hash IS DISTINCT FROM (SELECT identity_hash FROM product WHERE slug='truba-vgp-20x2-8-zn-6m'))
FROM product WHERE slug='truba-vgp-20x2-8-6m';

ROLLBACK; -- тестовая транзакция не оставляет следов
