-- ============================================================================
-- Справочники: единицы, словарь атрибутов, алиасы, категории пилота,
-- причины исходов, правила валидации, политики, конфиг. PostgreSQL 15+.
-- ============================================================================
BEGIN;
SET search_path TO onmi, public;

-- Пользователи
INSERT INTO app_user (user_id, login, full_name, role) VALUES
 ('00000000-0000-0000-0000-0000000000a1', 'system',  'Системные задания', 'system'),
 ('00000000-0000-0000-0000-0000000000a2', 'admin',   'Администратор каталога', 'admin');

-- Единицы и конверсии
INSERT INTO unit (unit_id, code, name_ru, is_weight) VALUES
 (1,'t','тонна',true), (2,'kg','килограмм',true), (3,'pcs','штука',false),
 (4,'m','метр',false), (5,'m2','квадратный метр',false), (6,'m3','кубический метр',false),
 (7,'mm','миллиметр',false);
INSERT INTO unit_conversion VALUES ((SELECT unit_id FROM unit WHERE code='t'),(SELECT unit_id FROM unit WHERE code='kg'),1000),
 ((SELECT unit_id FROM unit WHERE code='kg'),(SELECT unit_id FROM unit WHERE code='t'),0.001),
 ((SELECT unit_id FROM unit WHERE code='m'),(SELECT unit_id FROM unit WHERE code='mm'),1000),
 ((SELECT unit_id FROM unit WHERE code='mm'),(SELECT unit_id FROM unit WHERE code='m'),0.001);

-- Поставщик пилота и его склады (24 склада из тестового прайса)
INSERT INTO supplier (supplier_id, code, name_ru) VALUES
 ('00000000-0000-0000-0000-0000000000b1','metallservice','Металлсервис');
INSERT INTO supplier_warehouse (supplier_id, external_name)
SELECT (SELECT supplier_id FROM supplier WHERE code='metallservice'), w
FROM unnest(ARRAY['Курск','Самара','Пермь','Новосибирск','Екатеринбург','Челябинск','Чебоксары',
 'Нижний Новгород','Санкт-Петербург','Балашиха','Ростов-на-Дону','Таганрог','Брянск','Ногинск',
 'Хабаровск','Краснодар','Барнаул','Красноярск','Омск','Кемерово','Балаково','Ставрополь',
 'Белгород','Газгольдерная']) AS w;

-- Словарь атрибутов (коды прайса + русские имена каталога + атрибуты электроники)
INSERT INTO attribute (code, name_ru, data_type, measure_unit_id, normalizer, description) VALUES
 ('diameter','Диаметр','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm','мм, к точке, без хвостовых нулей'),
 ('wall_thickness','Толщина стенки','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm',''),
 ('thickness','Толщина','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm',''),
 ('width','Ширина','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm',''),
 ('length','Длина','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm','м -> мм'),
 ('size','Размер','text',NULL,'size_vector','вектор размеров, разделители х/x/*/× эквивалентны'),
 ('profile_type','Тип профиля','text',NULL,'upper_trim','30П, 30У, 10Б1...'),
 ('grade','Марка','enum',NULL,'grade_dict','словарь марок: кириллица=латиница для Х/А'),
 ('coating','Покрытие','enum',NULL,'',''),
 ('length_class','Класс длины','enum',NULL,'','6м/12м/немерная'),
 ('strength_class','Класс прочности','enum',NULL,'','5.8/8.8/10.9 — разные товары'),
 ('standard','Стандарт','text',NULL,'gost_norm','ГОСТ/DIN'),
 ('production_method','Тип проката','enum',NULL,'','г/к vs калиброванная — контрольный случай 4'),
 ('section_type','Тип сечения','enum',NULL,'','круглая/квадратная/прямоугольная'),
 ('surface','Поверхность','enum',NULL,'',''),
 ('dn','Диаметр DN','number',(SELECT unit_id FROM unit WHERE code='mm'),'number_mm','условный проход'),
 ('pn','Давление PN','number',NULL,'number_plain',''),
 ('weight_per_meter','Масса метра','number',(SELECT unit_id FROM unit WHERE code='kg'),'number_plain','для сверки с ГОСТ'),
 ('brand','Бренд','text',NULL,'brand_dict',''),
 ('model','Модель','text',NULL,'model_dict',''),
 ('memory','Объём памяти','enum',NULL,'',''),
 ('color','Цвет','enum',NULL,'','');

-- Канонические значения
INSERT INTO attribute_value (attribute_id, code, label_ru)
SELECT a.attribute_id, v.code, v.label FROM attribute a
JOIN (VALUES
 ('coating','uncoated','Без покрытия'),('coating','zn','Оцинкованный'),
 ('length_class','6m','Мерная 6 м'),('length_class','12m','Мерная 12 м'),('length_class','nd','Немерная'),('length_class','std','Стандартная'),
 ('strength_class','5_8','5.8'),('strength_class','8_8','8.8'),('strength_class','10_9','10.9'),
 ('production_method','hot_rolled','Горячекатаная'),('production_method','calibrated','Калиброванная'),('production_method','cold_drawn','Холоднотянутая'),
 ('section_type','round','Круглая'),('section_type','square','Квадратная'),('section_type','rectangular','Прямоугольная'),
 ('grade','st3sp','Ст3сп'),('grade','09g2s','09Г2С'),('grade','a240','А240'),('grade','a500c','А500С'),
 ('grade','aisi201','AISI 201'),('grade','aisi304','AISI 304'),('grade','40h13','40Х13'),
 ('memory','64gb','64 ГБ'),('memory','128gb','128 ГБ'),('memory','256gb','256 ГБ'),
 ('color','black','Чёрный'),('color','white','Белый')
) AS v(attr, code, label) ON v.attr = a.code;

-- Алиасы (написания поставщиков). Утверждённые примеры, включая кейс «н/д»:
INSERT INTO attribute_alias (attribute_id, alias_raw, attribute_value_id, supplier_id, status, created_by)
SELECT a.attribute_id, al.alias_raw, av.attribute_value_id,
       CASE WHEN al.supplier_scope THEN (SELECT supplier_id FROM supplier WHERE code='metallservice') END,
       'approved', (SELECT user_id FROM app_user WHERE login='system')
FROM (VALUES
 ('coating','оцинк.','zn',false),('coating','оц.','zn',false),('coating','Zn','zn',false),('coating','цинк','zn',false),
 ('coating','без покрытия','uncoated',false),('coating','чёрная','uncoated',false),
 ('length_class','н/д','nd',true),          -- у Металлсервиса «н/д» = немерная; трактовка привязана к поставщику
 ('length_class','немерная','nd',false),('length_class','6 м','6m',false),('length_class','6м','6m',false),
 ('length_class','L=6м','6m',false),('length_class','12 м','12m',false),('length_class','12м','12m',false),
 ('strength_class','8.8','8_8',false),('strength_class','кл.пр. 8,8','8_8',false),('strength_class','5.8','5_8',false),
 ('production_method','г/к','hot_rolled',false),('production_method','горячекатаная','hot_rolled',false),
 ('production_method','горячедеформированная','hot_rolled',false),('production_method','г/д','hot_rolled',false),
 ('production_method','калиброванная','calibrated',false),('production_method','калибр.','calibrated',false),
 ('production_method','х/т','cold_drawn',false),('production_method','х/д','cold_drawn',false),('production_method','холоднокатаная','cold_drawn',false)
) AS al(attr, alias_raw, target, supplier_scope)
JOIN attribute a ON a.code = al.attr
JOIN attribute_value av ON av.attribute_id = a.attribute_id AND av.code = al.target;

-- Категории пилота + демо новой ниши
INSERT INTO category (category_id, parent_id, name_ru, slug, path, level, canonical_unit_id) VALUES
 ('10000000-0000-0000-0000-0000000000c1', NULL, 'Металлопрокат', 'metall', 'metall', 1, NULL),
 ('10000000-0000-0000-0000-0000000000c2', '10000000-0000-0000-0000-0000000000c1', 'Трубы', 'truby', 'metall/truby', 2, NULL),
 ('10000000-0000-0000-0000-0000000000c3', '10000000-0000-0000-0000-0000000000c2', 'Трубы ВГП', 'truby-vgp', 'metall/truby/truby-vgp', 3, (SELECT unit_id FROM unit WHERE code='t')),
 ('10000000-0000-0000-0000-0000000000c4', '10000000-0000-0000-0000-0000000000c1', 'Швеллеры', 'shvellery', 'metall/shvellery', 2, (SELECT unit_id FROM unit WHERE code='t')),
 ('10000000-0000-0000-0000-0000000000d1', NULL, 'Электроника', 'electronics', 'electronics', 1, NULL),
 ('10000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d1', 'Смартфоны', 'smartfony', 'electronics/smartfony', 2, (SELECT unit_id FROM unit WHERE code='pcs'));

-- Атрибутный состав: identity пилотных категорий
INSERT INTO category_attribute (category_id, attribute_id, role)
SELECT c.category_id, a.attribute_id, x.role
FROM (VALUES
 ('metall/truby/truby-vgp','diameter','required'), ('metall/truby/truby-vgp','wall_thickness','required'),
 ('metall/truby/truby-vgp','coating','required'),   ('metall/truby/truby-vgp','length_class','required'),
 ('metall/truby/truby-vgp','grade','optional'),     ('metall/truby/truby-vgp','standard','optional'),
 ('metall/shvellery','profile_type','required'),    ('metall/shvellery','production_method','required'),
 ('metall/shvellery','grade','required'),           ('metall/shvellery','weight_per_meter','additional'),
 ('electronics/smartfony','brand','required'),      ('electronics/smartfony','model','required'),
 ('electronics/smartfony','memory','required'),     ('electronics/smartfony','color','optional')
) AS x(cat_path, attr_code, role)
JOIN category c ON c.path = x.cat_path
JOIN attribute a ON a.code = x.attr_code;

-- Норматив: швеллер 30П (контрольный случай 8: 7,05 кг вместо ~31,8)
INSERT INTO reference_norm (category_id, attribute_id, match_key, expected_value, tolerance_pct, source_ref)
SELECT c.category_id, a.attribute_id, '{"profile":"30П"}'::jsonb, 31.8, 10, 'ГОСТ 8240-97'
FROM category c, attribute a WHERE c.path='metall/shvellery' AND a.code='weight_per_meter';

-- Причины исходов: 15 реальных кодов текущего прайса + новые процессные
INSERT INTO reason_code (code, name_ru, requires_human) VALUES
 ('no_card_with_exact_family_dimensions_grade_and_form','Нет карточки с совпадающими семейством/размерами/маркой/формой',true),
 ('supplier_key_merges_multiple_source_families','Ключ поставщика склеивает несколько семейств',true),
 ('source_dimensions_do_not_identify_one_card','Размеры не определяют карточку однозначно',true),
 ('source_qualifier_has_no_canonical_attribute','Признак поставщика не отражён в каталоге',true),
 ('source_family_not_supported_by_onmi_metal_catalogue','Вид товара не представлен в каталоге',false),
 ('canonical_length_or_coil_form_missing_in_source','В источнике нет длины/формы поставки, нужных карточке',true),
 ('matching_cards_use_another_canonical_unit','Карточки этой категории используют другую единицу',true),
 ('ambiguous_source_grade','Марка в источнике неоднозначна',true),
 ('canonical_grade_missing_in_source','В источнике нет марки, нужной карточке',true),
 ('low_alloy_grade_missing','Не указана низколегированная марка',true),
 ('multiple_cards_match_available_source_attributes','Подходят несколько карточек',true),
 ('canonical_material_form_missing_in_source','В источнике нет формы материала',true),
 ('source_url_identifies_low_alloy_family_without_grade','URL определяет семейство без марки',true),
 ('source_url_identifies_galvanized_family_without_source_qualifier','Семейство оцинкованных без признака в источнике',true),
 ('category_unmapped','Категория поставщика не привязана к дереву',true),
 ('missing_required_attribute','Не извлечён обязательный атрибут',true),
 ('new_alias_value','Нераспознанное написание значения',true),
 ('unit_mismatch','Единица позиции несовместима с категорией',true),
 ('create_card_from_offer','Карточки нет — кандидат на создание',true),
 ('upgrade_card','Карточка есть, но с неполной идентичностью',true),
 ('stale_price_excluded','Цена старше срока актуальности',false),
 ('price_conflict','Несколько активных цен на позицию и склад',true);

-- Правила валидации
INSERT INTO validation_rule (code, severity, scope, name_ru, description) VALUES
 ('name_attr_dn_mismatch','block','product','Ду в названии != Ду в атрибутах','Парсим условное обозначение в названии, сверяем с атрибутами (кейс 7)'),
 ('name_attr_size_mismatch','block','product','Размер в названии != размеру в атрибутах',''),
 ('weight_norm_violation','block','product','Масса противоречит нормативу','Отклонение от reference_norm больше допуска (кейс 8)'),
 ('unit_weight_sanity','block','product','Подозрительные единица/вес','Например: штука + вес 1000 кг (кейс 9)'),
 ('identity_incomplete','warn','product','Не заполнены обязательные атрибуты','Карточка не может получать автопривязки'),
 ('price_outlier_vs_card_median','warn','offer_price','Цена-выброс против медианы карточки','Например НН за 29 тыс. при обычных 65'),
 ('stale_price','block','offer_price','Цена старше freshness_days','На сайт не публикуется (кейс 10)');

-- Политика состояний: безопасный дефолт, меняемый бизнесом
INSERT INTO condition_policy (condition_code, action, updated_by) VALUES
 ('normal','show',(SELECT user_id FROM app_user WHERE login='system')),
 ('nn','hide',(SELECT user_id FROM app_user WHERE login='system')),
 ('utsenka','hide',(SELECT user_id FROM app_user WHERE login='system')),
 ('nekonditsiya','hide',(SELECT user_id FROM app_user WHERE login='system'));

-- Конфиг конвейера
INSERT INTO config (config_key, value, description, updated_by) VALUES
 ('freshness_days','60','Сколько дней цена считается актуальной для витрины',(SELECT user_id FROM app_user WHERE login='system')),
 ('auto_link_min_confidence','0.95','Порог уверенности для автопривязки',(SELECT user_id FROM app_user WHERE login='system')),
 ('retire_after_missed_lists','3','После скольких прайсов без позиции переводить её в retired',(SELECT user_id FROM app_user WHERE login='system'));

COMMIT;
