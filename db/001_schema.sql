-- ============================================================================
-- ONMI: каталог, прайсы поставщиков и привязка позиций к карточкам
-- СУБД: PostgreSQL 15+.  Применение: psql -f 001_schema.sql && 002_seed.sql && 003_views.sql
-- Документация: docs/02-схема-бд.md (перечень таблиц), docs/03-маппинг.md (процесс)
-- ============================================================================
BEGIN;

CREATE SCHEMA IF NOT EXISTS onmi;
COMMENT ON SCHEMA onmi IS 'Каталог ONMI: справочники, сырьё поставщиков, офферы, канонический каталог, привязка, качество';

SET search_path TO onmi, public;
SET LOCAL client_min_messages = warning;

-- ============================================================================
-- 0. АКТОРЫ (нужен ссылкам из справочников и решений)
-- ============================================================================
CREATE TABLE app_user (
    user_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    login      text NOT NULL UNIQUE,
    full_name  text NOT NULL,
    role       text NOT NULL DEFAULT 'analyst' CHECK (role IN ('analyst', 'admin', 'system')),
    is_active  boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE app_user IS 'Люди и системные задания, принимающие решения (кто привязал, кто разобрал спор, кто одобрил алиас)';

-- ============================================================================
-- 1. СПРАВОЧНИКИ (reference)
-- ============================================================================
CREATE TABLE unit (
    unit_id   smallint PRIMARY KEY,
    code      text NOT NULL UNIQUE,             -- t, kg, pcs, m, m2, m3
    name_ru   text NOT NULL,
    is_weight boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE unit IS 'Единицы измерения';

CREATE TABLE unit_conversion (
    from_unit_id smallint NOT NULL REFERENCES unit,
    to_unit_id   smallint NOT NULL REFERENCES unit,
    factor       numeric NOT NULL CHECK (factor > 0),
    PRIMARY KEY (from_unit_id, to_unit_id)
);
COMMENT ON TABLE unit_conversion IS 'Разрешённые конверсии единиц. Нет записи — конверсия запрещена (фланец в тоннах не станет штукой)';

CREATE TABLE attribute (
    attribute_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL UNIQUE,       -- diameter, wall_thickness, grade, coating, brand...
    name_ru         text NOT NULL,
    data_type       text NOT NULL CHECK (data_type IN ('enum', 'number', 'text')),
    measure_unit_id smallint REFERENCES unit,   -- для number-атрибутов: мм, кг...
    normalizer      text,                       -- имя нормализатора значения в коде конвейера
    description     text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE attribute IS 'Словарь атрибутов всех ниш. Единый код и для каталога («Размер»), и для прайсов (size)';

CREATE TABLE attribute_value (
    attribute_value_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attribute_id  integer NOT NULL REFERENCES attribute ON DELETE CASCADE,
    code          text NOT NULL,                -- zn, 6m, 09g2s
    label_ru      text NOT NULL,
    UNIQUE (attribute_id, code)
);
COMMENT ON TABLE attribute_value IS 'Канонические значения enum-атрибутов';

CREATE TABLE category (
    category_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id         uuid REFERENCES category,
    name_ru           text NOT NULL,
    slug              text NOT NULL,
    path              text NOT NULL UNIQUE,     -- материализованный путь: 'metall/truby/truby-vgp'
    level             smallint NOT NULL CHECK (level BETWEEN 1 AND 5),
    canonical_unit_id smallint REFERENCES unit, -- каноническая единица продажи категории
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (parent_id, slug),
    CHECK (level = 1 OR parent_id IS NOT NULL)
);
COMMENT ON TABLE category IS 'Дерево категорий. path уникален — адреса разделов стабильны';

CREATE TABLE category_attribute (
    category_id  uuid NOT NULL REFERENCES category ON DELETE CASCADE,
    attribute_id integer NOT NULL REFERENCES attribute,
    role         text NOT NULL CHECK (role IN ('required', 'optional', 'additional')),
    sort_order   integer NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid REFERENCES app_user,
    PRIMARY KEY (category_id, attribute_id)
);
COMMENT ON TABLE category_attribute IS 'Атрибутный состав категории: required входит в identity товара; изменение состава версионировать в git';

CREATE TABLE condition_policy (
    condition_code text PRIMARY KEY CHECK (condition_code IN ('normal', 'nn', 'utsenka', 'nekonditsiya')),
    action         text NOT NULL DEFAULT 'hide' CHECK (action IN ('show', 'hide', 'separate_card')),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid REFERENCES app_user
);
COMMENT ON TABLE condition_policy IS 'Политика видимости состояний: «НН»/уценка/некондиция. Бизнес-решение, меняется данными, без релиза';

CREATE TABLE reason_code (
    reason_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE,
    name_ru        text NOT NULL,
    requires_human boolean NOT NULL DEFAULT true,
    description    text
);
COMMENT ON TABLE reason_code IS 'Причины исходов позиций. 16 кодов перенесены из текущего прайса, чтобы отчёты были сопоставимы';

-- ============================================================================
-- 2. ПОСТАВЩИКИ И СЫРЬЁ (source)
-- ============================================================================
CREATE TABLE supplier (
    supplier_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,           -- metallservice
    name_ru     text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE supplier IS 'Поставщики прайсов';

CREATE TABLE supplier_warehouse (
    warehouse_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id   uuid NOT NULL REFERENCES supplier,
    external_name text NOT NULL,                -- 'Балаково'
    region        text,
    is_active     boolean NOT NULL DEFAULT true,
    UNIQUE (supplier_id, external_name)
);
COMMENT ON TABLE supplier_warehouse IS 'Склады поставщика (в тестовом прайсе Металлсервиса — 24)';

CREATE TABLE price_list (
    price_list_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id   uuid NOT NULL REFERENCES supplier,
    file_name     text NOT NULL,
    file_sha256   text NOT NULL CHECK (char_length(file_sha256) = 64),
    received_at   timestamptz NOT NULL DEFAULT now(),
    status        text NOT NULL DEFAULT 'loaded'
                  CHECK (status IN ('loaded', 'parsed', 'processing', 'published', 'failed', 'duplicate')),
    rows_total    integer,
    rows_accepted integer,
    loaded_by     uuid REFERENCES app_user,
    note          text,
    UNIQUE (supplier_id, file_sha256)           -- контрольный случай 12: повторная загрузка = no-op
);
COMMENT ON TABLE price_list IS 'Прайс-файл. Дедупликация по SHA-256 в рамках поставщика';

CREATE TABLE price_list_row (
    row_id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    price_list_id      uuid NOT NULL REFERENCES price_list ON DELETE CASCADE,
    row_number         integer NOT NULL,
    warehouse_name     text,
    supplier_category  text,
    title_raw          text NOT NULL,
    attributes_raw     text,
    unit_raw           text,
    price_vat          numeric(14,2) CHECK (price_vat IS NULL OR price_vat > 0),
    price_no_vat       numeric(14,2) CHECK (price_no_vat IS NULL OR price_no_vat > 0),
    price_date         date,
    source_url         text,
    raw_json           jsonb,                    -- всё, что не вошло в типизированные колонки
    CHECK (price_vat IS NOT NULL OR price_no_vat IS NOT NULL OR raw_json IS NOT NULL),
    UNIQUE (price_list_id, row_number)
);
COMMENT ON TABLE price_list_row IS 'Сырые строки файла, append-only (роль etl_raw не имеет UPDATE/DELETE). Перепрогоняется при взятии категории в работу';

-- ============================================================================
-- 3. НОРМАЛИЗОВАННЫЕ ПОЗИЦИИ ПОСТАВЩИКА (offer)
-- ============================================================================
CREATE TABLE attribute_alias (
    alias_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attribute_id       integer NOT NULL REFERENCES attribute,
    alias_raw          text NOT NULL,           -- 'оцинк.', 'Zn', 'н/д'
    attribute_value_id integer REFERENCES attribute_value,
    supplier_id        uuid REFERENCES supplier, -- NULL = глобальный алиас; 'н/д' трактуется поставщиком
    status             text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'approved', 'rejected')),
    created_by         uuid REFERENCES app_user,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (attribute_id, alias_raw, supplier_id)
);
COMMENT ON TABLE attribute_alias IS 'Написания поставщиков -> канонические значения. Новое написание = candidate + задача; approve превращает ручную работу в автопривязку';

CREATE TABLE offer (
    offer_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id        uuid NOT NULL REFERENCES supplier,
    natural_key_hash   text NOT NULL,
    natural_key        text NOT NULL,            -- человекочитаемый ключ для разбора споров
    supplier_item_code text,                     -- код позиции у поставщика, если есть
    condition          text NOT NULL DEFAULT 'normal' CHECK (condition IN ('normal', 'nn', 'utsenka', 'nekonditsiya')),
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired')),
    current_title      text,
    current_unit_id    smallint REFERENCES unit,
    first_seen_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz NOT NULL DEFAULT now(),
    retired_at         timestamptz,
    UNIQUE (supplier_id, natural_key_hash)       -- идемпотентность повторных загрузок
);
COMMENT ON TABLE offer IS 'Позиция поставщика как устойчивая сущность. Natural key = нормализованные атрибуты, не текст названия';

CREATE TABLE offer_snapshot (
    offer_snapshot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id          uuid NOT NULL REFERENCES offer ON DELETE CASCADE,
    price_list_id     uuid NOT NULL REFERENCES price_list,
    title_raw         text NOT NULL,
    attributes_raw    text,
    unit_raw          text,
    attrs_parsed      jsonb,
    changed_fields    text[],                    -- diff с предыдущим снапшотом (случай 11)
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (offer_id, price_list_id)
);
COMMENT ON TABLE offer_snapshot IS 'Как позиция выглядела в конкретном прайсе. История изменений описаний';

CREATE TABLE offer_attribute (
    offer_id           uuid NOT NULL REFERENCES offer ON DELETE CASCADE,
    attribute_id       integer NOT NULL REFERENCES attribute,
    value_raw          text,
    attribute_value_id integer REFERENCES attribute_value,   -- для enum
    value_number       numeric,                                 -- для number
    value_text         text,                                    -- для text
    parsed_from        text NOT NULL DEFAULT 'title' CHECK (parsed_from IN ('column', 'title', 'spec_url', 'manual')),
    confidence         numeric CHECK (confidence BETWEEN 0 AND 1),
    PRIMARY KEY (offer_id, attribute_id)
);
COMMENT ON TABLE offer_attribute IS 'Типизированные атрибуты позиции в едином словаре attribute/attribute_value';

CREATE TABLE offer_price (
    offer_price_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id       uuid NOT NULL REFERENCES offer ON DELETE CASCADE,
    warehouse_id   uuid NOT NULL REFERENCES supplier_warehouse,
    price_list_id  uuid NOT NULL REFERENCES price_list,
    source_row_id  bigint REFERENCES price_list_row,             -- происхождение до строки файла
    price_vat      numeric(14,2) CHECK (price_vat > 0),
    price_no_vat   numeric(14,2) CHECK (price_no_vat IS NULL OR price_no_vat > 0),
    unit_id        smallint NOT NULL REFERENCES unit,            -- единица, за которую цена
    price_date     date NOT NULL,                                -- дата прайса-источника (в файле МС их две!)
    valid_from     timestamptz NOT NULL DEFAULT now(),
    valid_to       timestamptz,                                  -- NULL = активная
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (price_vat IS NOT NULL OR price_no_vat IS NOT NULL)
);
CREATE UNIQUE INDEX uq_offer_price_active ON offer_price (offer_id, warehouse_id) WHERE valid_to IS NULL;
CREATE INDEX idx_offer_price_date ON offer_price (price_date);
COMMENT ON TABLE offer_price IS 'Цена и наличие: позиция x склад x интервал. Одна активная цена обеспечена индексом uq_offer_price_active';

-- ============================================================================
-- 4. КАНОНИЧЕСКИЙ КАТАЛОГ (catalog)
-- ============================================================================
CREATE TABLE product (
    product_id    uuid PRIMARY KEY,              -- переносится из текущего каталога (адреса страниц не меняются)
    legacy_code   text UNIQUE,                   -- 'Артикул ONMI' для переноса существующих привязок
    code          text UNIQUE,
    slug          text NOT NULL UNIQUE,          -- URL карточки стабилен
    name_ru       text NOT NULL,
    category_id   uuid NOT NULL REFERENCES category,
    unit_id       smallint NOT NULL REFERENCES unit,
    weight_kg     numeric(12,3) CHECK (weight_kg IS NULL OR weight_kg > 0),
    volume_m3     numeric(12,5) CHECK (volume_m3 IS NULL OR volume_m3 > 0),
    identity_hash text,                          -- предвычислен из обязательных атрибутов; NULL = набор неполон
    work_status   text NOT NULL DEFAULT 'todo' CHECK (work_status IN ('todo', 'in_review', 'ready', 'published', 'archived')),
    source        text NOT NULL DEFAULT 'migration' CHECK (source IN ('migration', 'manual', 'offer_derived')),
    problems      text,                          -- перенесённые пометки старого каталога
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, category_id)             -- опора составного FK из product_attribute
);
CREATE UNIQUE INDEX uq_product_identity ON product (category_id, identity_hash) WHERE identity_hash IS NOT NULL;
COMMENT ON TABLE product IS 'Карточка сайта. uq_product_identity: два одинаковых товара в категории невозможны (анти-дробление и анти-склейка)';

CREATE TABLE product_attribute (
    product_id         uuid NOT NULL,
    category_id        uuid NOT NULL,
    attribute_id       integer NOT NULL,
    attribute_value_id integer REFERENCES attribute_value,
    value_number       numeric,
    value_text         text,
    source             text NOT NULL DEFAULT 'migration' CHECK (source IN ('migration', 'manual', 'offer_derived')),
    is_verified        boolean NOT NULL DEFAULT false,
    verified_by        uuid REFERENCES app_user,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, attribute_id),
    FOREIGN KEY (product_id, category_id) REFERENCES product (product_id, category_id),
    FOREIGN KEY (category_id, attribute_id) REFERENCES category_attribute (category_id, attribute_id)
);
COMMENT ON TABLE product_attribute IS 'Атрибуты карточки. Составной FK-замок: атрибут, не объявленный для категории, вставить нельзя';

CREATE TABLE product_media (
    media_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id uuid NOT NULL REFERENCES product ON DELETE CASCADE,
    url        text NOT NULL,
    status     text NOT NULL DEFAULT 'todo' CHECK (status IN ('ok', 'missing', 'todo')),
    action     text,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE product_media IS 'Изображения карточек (перенос image_url/image_status текущего каталога)';

CREATE TABLE reference_norm (
    norm_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id    uuid NOT NULL REFERENCES category,
    attribute_id   integer NOT NULL REFERENCES attribute,   -- обычно weight_per_meter
    match_key      jsonb NOT NULL,                           -- {"profile": "30П"}
    expected_value numeric NOT NULL CHECK (expected_value > 0),
    tolerance_pct  numeric NOT NULL DEFAULT 10 CHECK (tolerance_pct BETWEEN 0 AND 100),
    source_ref     text,                                     -- 'ГОСТ 8240-97'
    is_active      boolean NOT NULL DEFAULT true,
    UNIQUE (category_id, attribute_id, match_key)
);
COMMENT ON TABLE reference_norm IS 'Нормативы: швеллер 30П -> 31,8 кг/м. Ловит массу 7,05 кг отклонением в 4,5 раза';

-- ============================================================================
-- 5. СВЯЗКА ПРАЙС <-> КАТАЛОГ (match)
-- ============================================================================
CREATE TABLE supplier_category_map (
    supplier_id           uuid NOT NULL REFERENCES supplier,
    supplier_category_raw text NOT NULL,        -- 'Металлопрокат / ТРУБЫ ЭЛЕКТРОСВАРНЫЕ'
    category_id           uuid REFERENCES category,
    status                text NOT NULL DEFAULT 'needs_review' CHECK (status IN ('mapped', 'needs_review', 'ignored')),
    mapped_by             uuid REFERENCES app_user,
    mapped_at             timestamptz,
    note                  text,
    PRIMARY KEY (supplier_id, supplier_category_raw)
);
COMMENT ON TABLE supplier_category_map IS 'Категория поставщика -> наша. ignored = осознанное «вид не возим» с автором, а не потеря позиций';

CREATE TABLE card_link (
    link_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    offer_id         uuid NOT NULL REFERENCES offer,
    product_id       uuid NOT NULL REFERENCES product,
    status           text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'active', 'needs_review', 'auto_expired', 'rejected')),
    method           text NOT NULL CHECK (method IN ('rules_exact', 'rules_disambiguated', 'manual', 'llm_suggest', 'legacy_import')),
    confidence       numeric CHECK (confidence BETWEEN 0 AND 1),
    rule_trace       jsonb,                      -- какие правила сработали: трасса решения
    decision_by_type text NOT NULL DEFAULT 'job' CHECK (decision_by_type IN ('user', 'job', 'system')),
    decision_by_id   uuid,                       -- app_user.user_id или pipeline_run.run_id
    reason           text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    decided_at       timestamptz,
    valid_from       timestamptz NOT NULL DEFAULT now(),
    valid_to         timestamptz,
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    UNIQUE (offer_id, product_id)                -- история пары не плодится: перелинковка обновляет строку
);
CREATE UNIQUE INDEX uq_card_link_active ON card_link (offer_id) WHERE status = 'active';
CREATE INDEX idx_card_link_product ON card_link (product_id) WHERE status = 'active';
COMMENT ON TABLE card_link IS 'Привязка позиции к карточке. uq_card_link_active: активная привязка ровно одна (код на двух страницах невозможен). Активацию охраняет триггер tg_card_link_guard';

-- ============================================================================
-- 6. КАЧЕСТВО И ОПЕРАЦИИ (ops)
-- ============================================================================
CREATE TABLE review_task (
    task_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_type       text NOT NULL CHECK (subject_type IN ('offer', 'alias', 'product', 'category_map', 'price_conflict')),
    subject_id         text NOT NULL,
    reason_code        text NOT NULL REFERENCES reason_code (code),
    payload            jsonb,                    -- кандидаты-карточки, diff, недостающие атрибуты
    priority           smallint NOT NULL DEFAULT 100,
    status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'claimed', 'resolved', 'dismissed')),
    assigned_to        uuid REFERENCES app_user,
    created_at         timestamptz NOT NULL DEFAULT now(),
    claimed_at         timestamptz,
    resolved_at        timestamptz,
    resolution_type    text CHECK (resolution_type IN ('linked', 'created_product', 'added_alias', 'upgraded_card', 'fixed_data', 'mapped_category', 'ignored')),
    resolution_payload jsonb,                    -- что именно сделал человек: id карточки, алиас...
    closed_by          uuid REFERENCES app_user
);
CREATE UNIQUE INDEX uq_review_open ON review_task (subject_type, subject_id, reason_code) WHERE status IN ('open', 'claimed');
CREATE INDEX idx_review_queue ON review_task (status, priority, created_at);
COMMENT ON TABLE review_task IS 'Очередь ручной работы с типизацией причин и фиксацией разрешения. Разрешение кормит справочники -> следующий прогон умнее';

CREATE TABLE validation_rule (
    rule_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       text NOT NULL UNIQUE,
    severity   text NOT NULL CHECK (severity IN ('block', 'warn', 'info')),
    scope      text NOT NULL CHECK (scope IN ('product', 'offer', 'card_link', 'offer_price')),
    name_ru    text NOT NULL,
    description text,
    is_active  boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE validation_rule IS 'Правила качества. block останавливает публикацию затронутых сущностей';

CREATE TABLE validation_result (
    result_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id    integer NOT NULL REFERENCES validation_rule,
    entity_type text NOT NULL,
    entity_id   text NOT NULL,
    severity_at_detection text NOT NULL,
    details    jsonb,
    detected_at timestamptz NOT NULL DEFAULT now(),
    status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'ignored')),
    resolved_at timestamptz,
    resolved_by uuid REFERENCES app_user
);
CREATE UNIQUE INDEX uq_validation_open ON validation_result (rule_id, entity_type, entity_id) WHERE status = 'open';
COMMENT ON TABLE validation_result IS 'Открытые проблемы качества. uq_validation_open не плодит дубли при повторных прогонах';

CREATE TABLE golden_set (
    golden_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id            uuid NOT NULL UNIQUE REFERENCES offer,
    expected_product_id uuid NOT NULL REFERENCES product,
    verified_by         uuid REFERENCES app_user,
    note                text,
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE golden_set IS 'Эталонная разметка для регрессионного теста правил: без прохождения порогов точности правила не выкатываются';

CREATE TABLE pipeline_run (
    run_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type        text NOT NULL CHECK (job_type IN ('ingest', 'normalize', 'match', 'validate', 'publish', 'migrate')),
    price_list_id   uuid REFERENCES price_list,
    ruleset_version text,                        -- git-SHA репозитория правил
    params          jsonb,
    status          text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'failed')),
    stats           jsonb,                       -- {linked, review, rejected, ignored} - баланс исходов
    error           text,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz
);
COMMENT ON TABLE pipeline_run IS 'Каждый прогон конвейера. Счётчики исходов должны сходиться с числом строк прайса';

CREATE TABLE audit_log (
    entry_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_type text NOT NULL,
    entity_id   text NOT NULL,
    action      text NOT NULL,
    actor_type  text,                            -- из set_config('app.actor_type', ...)
    actor_id    text,
    before_json jsonb,
    after_json  jsonb,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_log (entity_type, entity_id, at);
COMMENT ON TABLE audit_log IS 'Журнал изменений критичных таблиц (триггерно, не зависит от дисциплины кода)';

CREATE TABLE config (
    config_key  text PRIMARY KEY,
    value       jsonb NOT NULL,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES app_user
);
COMMENT ON TABLE config IS 'Параметры конвейера: freshness_days, auto_link_min_confidence, retire_after_missed_lists';

-- ============================================================================
-- 7. ФУНКЦИИ И ТРИГГЕРЫ-ИНВАРИАНТЫ
-- ============================================================================
-- updated_at
CREATE OR REPLACE FUNCTION fn_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER tg_product_touch BEFORE UPDATE ON product
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER tg_category_attribute_touch BEFORE UPDATE ON category_attribute
    FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- Каноническое значение атрибута: единая для каталога и офферов функция канонизации
CREATE OR REPLACE FUNCTION fn_attr_canonical_value(
    p_attribute_id       integer,
    p_attribute_value_id integer DEFAULT NULL,
    p_value_number       numeric  DEFAULT NULL,
    p_value_text         text     DEFAULT NULL
) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE a.data_type
        WHEN 'enum'   THEN (SELECT av.code FROM attribute_value av WHERE av.attribute_value_id = p_attribute_value_id)
        WHEN 'number' THEN rtrim(rtrim(to_char(p_value_number, 'FM999999999990.999999999'), '0'), '.')
        ELSE lower(btrim(coalesce(p_value_text, '')))
    END
    FROM attribute a
    WHERE a.attribute_id = p_attribute_id
      AND a.data_type = CASE WHEN p_attribute_value_id IS NOT NULL THEN 'enum'
                             WHEN p_value_number IS NOT NULL THEN 'number'
                             ELSE a.data_type END
$$;

-- identity карточки: md5 по обязательным атрибутам категории; NULL, если набор неполон
CREATE OR REPLACE FUNCTION fn_product_identity(p_product_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_category uuid;
    v_required int;
    v_filled   int;
    v_hash     text;
BEGIN
    SELECT category_id INTO v_category FROM product WHERE product_id = p_product_id;
    IF v_category IS NULL THEN RETURN NULL; END IF;

    SELECT count(*) INTO v_required
    FROM category_attribute WHERE category_id = v_category AND role = 'required';

    SELECT count(*) INTO v_filled
    FROM category_attribute ca
    JOIN product_attribute pa
      ON pa.product_id = p_product_id AND pa.attribute_id = ca.attribute_id
    WHERE ca.category_id = v_category AND ca.role = 'required'
      AND fn_attr_canonical_value(pa.attribute_id, pa.attribute_value_id, pa.value_number, pa.value_text) IS NOT NULL;

    IF v_required = 0 OR v_filled < v_required THEN RETURN NULL; END IF;

    SELECT md5(v_category::text || ':' || string_agg(
               a.code || '=' || fn_attr_canonical_value(pa.attribute_id, pa.attribute_value_id, pa.value_number, pa.value_text),
               ',' ORDER BY a.code))
    INTO v_hash
    FROM category_attribute ca
    JOIN attribute a  ON a.attribute_id = ca.attribute_id
    JOIN product_attribute pa ON pa.product_id = p_product_id AND pa.attribute_id = ca.attribute_id
    WHERE ca.category_id = v_category AND ca.role = 'required';

    RETURN v_hash;
END $$;

-- identity позиции, посчитанная по обязательным атрибутам заданной категории
CREATE OR REPLACE FUNCTION fn_offer_identity_for_category(p_offer_id uuid, p_category_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_required int;
    v_filled   int;
    v_hash     text;
BEGIN
    SELECT count(*) INTO v_required
    FROM category_attribute WHERE category_id = p_category_id AND role = 'required';

    SELECT count(*) INTO v_filled
    FROM category_attribute ca
    JOIN offer_attribute oa
      ON oa.offer_id = p_offer_id AND oa.attribute_id = ca.attribute_id
    WHERE ca.category_id = p_category_id AND ca.role = 'required'
      AND fn_attr_canonical_value(oa.attribute_id, oa.attribute_value_id, oa.value_number, oa.value_text) IS NOT NULL;

    IF v_required = 0 OR v_filled < v_required THEN RETURN NULL; END IF;

    SELECT md5(p_category_id::text || ':' || string_agg(
               a.code || '=' || fn_attr_canonical_value(oa.attribute_id, oa.attribute_value_id, oa.value_number, oa.value_text),
               ',' ORDER BY a.code))
    INTO v_hash
    FROM category_attribute ca
    JOIN attribute a ON a.attribute_id = ca.attribute_id
    JOIN offer_attribute oa ON oa.offer_id = p_offer_id AND oa.attribute_id = ca.attribute_id
    WHERE ca.category_id = p_category_id AND ca.role = 'required';

    RETURN v_hash;
END $$;

-- Пересчёт identity карточки при изменении её атрибутов или категории
CREATE OR REPLACE FUNCTION tg_product_identity_recompute() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_product uuid := COALESCE(NEW.product_id, OLD.product_id);
BEGIN
    UPDATE product SET identity_hash = fn_product_identity(v_product)
    WHERE product_id = v_product;
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER tg_pa_identity AFTER INSERT OR UPDATE OR DELETE ON product_attribute
    FOR EACH ROW EXECUTE FUNCTION tg_product_identity_recompute();

CREATE TRIGGER tg_product_category_identity AFTER UPDATE OF category_id ON product
    FOR EACH ROW WHEN (OLD.category_id IS DISTINCT FROM NEW.category_id)
    EXECUTE FUNCTION tg_product_identity_recompute();

-- Страж привязки: активировать card_link можно только при полной совместимости
CREATE OR REPLACE FUNCTION tg_card_link_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_category  uuid;
    v_p_identity text;
    v_o_identity text;
    v_unit_p    smallint;
    v_unit_o    smallint;
    v_condition text;
    v_action    text;
    v_blocks    int;
BEGIN
    IF NEW.status <> 'active' THEN RETURN NEW; END IF;

    SELECT p.category_id, p.unit_id, p.identity_hash INTO v_category, v_unit_p, v_p_identity
    FROM product p WHERE p.product_id = NEW.product_id;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'card_link: карточка % не найдена', NEW.product_id;
    END IF;

    v_o_identity := fn_offer_identity_for_category(NEW.offer_id, v_category);

    IF v_p_identity IS NULL THEN
        RAISE EXCEPTION 'card_link: у карточки % не заполнены обязательные атрибуты категории % — активация запрещена', NEW.product_id, v_category;
    END IF;
    IF v_o_identity IS NULL THEN
        RAISE EXCEPTION 'card_link: у позиции % не извлечены обязательные атрибуты (категория %) — активация запрещена', NEW.offer_id, v_category;
    END IF;
    IF v_o_identity <> v_p_identity THEN
        RAISE EXCEPTION 'card_link: обязательные атрибуты позиции % и карточки % не совпадают (%) <> (%)', NEW.offer_id, NEW.product_id, v_o_identity, v_p_identity;
    END IF;

    SELECT o.condition, o.current_unit_id INTO v_condition, v_unit_o
    FROM offer o WHERE o.offer_id = NEW.offer_id;

    SELECT action INTO v_action FROM condition_policy WHERE condition_code = v_condition;
    IF v_action = 'hide' THEN
        RAISE EXCEPTION 'card_link: позиция % в состоянии «%» скрыта политикой — публикация запрещена', NEW.offer_id, v_condition;
    END IF;

    IF v_unit_o IS NOT NULL AND v_unit_o <> v_unit_p AND NOT EXISTS (
        SELECT 1 FROM unit_conversion c
        WHERE c.from_unit_id = v_unit_o AND c.to_unit_id = v_unit_p) THEN
        RAISE EXCEPTION 'card_link: единица позиции (%) несовместима с единицей карточки (%)', v_unit_o, v_unit_p;
    END IF;

    SELECT count(*) INTO v_blocks
    FROM validation_result vr
    JOIN validation_rule r ON r.rule_id = vr.rule_id
    WHERE vr.entity_type = 'product' AND vr.entity_id = NEW.product_id::text
      AND vr.status = 'open' AND r.severity = 'block';
    IF v_blocks > 0 THEN
        RAISE EXCEPTION 'card_link: у карточки % открытых блокирующих проблем валидации: %', NEW.product_id, v_blocks;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER tg_card_link_guard BEFORE INSERT OR UPDATE OF status ON card_link
    FOR EACH ROW EXECUTE FUNCTION tg_card_link_guard();

-- Аудит критичных таблиц
CREATE OR REPLACE FUNCTION tg_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    j jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
    v_entity_id text;
BEGIN
    v_entity_id := COALESCE(
        j->>'link_id', j->>'alias_id', j->>'condition_code', j->>'supplier_id',
        concat_ws(':', j->>'category_id', j->>'attribute_id'), '?');
    INSERT INTO audit_log (entity_type, entity_id, action, actor_type, actor_id, before_json, after_json)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_entity_id, TG_OP,
            current_setting('app.actor_type', true), current_setting('app.actor_id', true),
            CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END);
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER tg_audit_card_link AFTER INSERT OR UPDATE OR DELETE ON card_link
    FOR EACH ROW EXECUTE FUNCTION tg_audit();
CREATE TRIGGER tg_audit_alias AFTER INSERT OR UPDATE OR DELETE ON attribute_alias
    FOR EACH ROW EXECUTE FUNCTION tg_audit();
CREATE TRIGGER tg_audit_category_attribute AFTER INSERT OR UPDATE OR DELETE ON category_attribute
    FOR EACH ROW EXECUTE FUNCTION tg_audit();
CREATE TRIGGER tg_audit_condition_policy AFTER INSERT OR UPDATE OR DELETE ON condition_policy
    FOR EACH ROW EXECUTE FUNCTION tg_audit();
CREATE TRIGGER tg_audit_supplier_category_map AFTER INSERT OR UPDATE OR DELETE ON supplier_category_map
    FOR EACH ROW EXECUTE FUNCTION tg_audit();

COMMIT;
