-- Publica as tabelas geográficas do schema dw como camadas do mapa.
-- Roda depois da migração (precisa do dw): ./etl/migrar_dw.sh camadas
-- Para cada camada: função tiles.<id> (lida pelo Martin) + linha em geo.camada (lida pelo mapa e pela API).

-- Gera tiles.<id>(z, x, y, query_params) para uma tabela com coluna geom em SIRGAS 2000 (4674).
--   p_from      : FROM com alias "t" para a tabela da geometria (pode ter JOINs de domínio)
--   p_atributos : colunas que vão para o tile — nunca CPF/CNPJ/nomes de pessoas (tiles ficam em cache público)
--   p_id_col    : coluna inteira usada como id da feição (destaque/clique), ou NULL
CREATE OR REPLACE PROCEDURE tiles.publicar_camada(p_id text, p_from text, p_atributos text, p_minzoom int,
                                                  p_id_col text DEFAULT 'id', p_filtro text DEFAULT 'true')
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION tiles.%1$I(z integer, x integer, y integer, query_params json)
        RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $fn$
            WITH b AS (
                SELECT ST_TileEnvelope(z, x, y) AS env,
                       ST_Transform(ST_TileEnvelope(z, x, y, margin => 64.0 / 4096), 4674) AS env_4674,
                       -- meio pixel do tile em graus: simplifica antes de projetar (zoom baixo fica leve)
                       180.0 / (4096 * 2 ^ z) AS tol
            ), f AS (
                SELECT %2$s,
                       ST_AsMVTGeom(ST_Transform(ST_Simplify(t.geom, b.tol), 3857), b.env, 4096, 64, true) AS geom
                  FROM %3$s
                 CROSS JOIN b
                 WHERE z >= %4$s AND t.geom && b.env_4674 AND (%5$s)
            )
            SELECT ST_AsMVT(f, %1$L, 4096, 'geom' %6$s) FROM f WHERE f.geom IS NOT NULL;
        $fn$
    $f$, p_id, p_atributos, p_from, p_minzoom, p_filtro,
         CASE WHEN p_id_col IS NULL THEN '' ELSE format(', %L', p_id_col) END);
END $$;

-- id | nome | grupo | fonte | tipo | cor | minzoom | tabela p/ sobreposição | ativo | FROM | atributos | id
CREATE TEMP TABLE camadas_dw (
    id text, nome text, grupo text, fonte text, tipo text, cor text, minzoom int, tabela text, ativo boolean,
    p_from text, p_atributos text, p_id_col text, p_filtro text DEFAULT 'true', ordem serial
);

INSERT INTO camadas_dw (id, nome, grupo, fonte, tipo, cor, minzoom, tabela, ativo, p_from, p_atributos, p_id_col) VALUES
('uf_limite', 'Limites estaduais', 'Limites', 'IBGE', 'linha', '#495057', 0, NULL, true,
 'dw.dm_uf_geo t JOIN dw.dm_uf u ON u.id = t.uf_id', 't.uf_id AS id, u.sg_uf AS uf, u.nm_uf AS nome', 'id'),
('bioma', 'Biomas', 'Limites', 'IBGE', 'poligono', '#74b816', 0, NULL, false,
 'dw.dm_bioma_geo t JOIN dw.dm_bioma bi ON bi.id = t.bioma_id', 't.bioma_id AS id, bi.nm_bioma AS nome', 'id'),
('faixa_fronteira', 'Faixa de fronteira', 'Limites', 'IBGE', 'poligono', '#fd7e14', 4, NULL, false,
 'dw.dm_faixa_fronteira_geo t', 't.faixa_fronteira_id AS id, t.uf_id', NULL),

('sicar', 'Imóveis CAR (SICAR)', 'Fundiário', 'SICAR', 'poligono', '#2b8a3e', 10, 'dw.dm_sicar_geo', true,
 'dw.dm_sicar_geo t JOIN dw.dm_sicar s ON s.id = t.sicar_id AND s.uf_id = t.uf_id
  LEFT JOIN dw.ta_sicar_status st ON st.id = s.sicar_status_id
  LEFT JOIN dw.ta_sicar_tipo_imovel ti ON ti.id = s.sicar_tipo_imovel_id',
 's.id, s.cod_imovel, st.tx_descricao AS status, ti.tx_descricao AS tipo, round(s.area_ha, 2) AS area_ha', 'id'),
('sigef', 'Parcelas SIGEF', 'Fundiário', 'INCRA/SIGEF', 'poligono', '#5f3dc4', 10, 'dw.dm_sigef', false,
 'dw.dm_sigef t LEFT JOIN dw.ta_sigef_status st ON st.id = t.sigef_status_id
  LEFT JOIN dw.ta_sigef_natureza na ON na.id = t.sigef_natureza_id',
 't.id, t.nm_area, t.qrcode, st.tx_descricao AS status, na.tx_descricao AS natureza, round(t.area_ha, 2) AS area_ha', 'id'),
('assentamento', 'Assentamentos', 'Fundiário', 'INCRA', 'poligono', '#1971c2', 5, 'dw.dm_assentamento', false,
 'dw.dm_assentamento t', 't.id, t.projeto, t.cd_sipra, t.nu_familia, round(t.area_ha, 2) AS area_ha', 'id'),
('area_urbana', 'Áreas urbanas', 'Fundiário', 'IBGE', 'poligono', '#868e96', 8, 'dw.dm_area_urbana', false,
 'dw.dm_area_urbana t', 't.id, round(t.area_ha, 2) AS area_ha', 'id'),

('terra_indigena', 'Terras indígenas', 'Áreas protegidas', 'FUNAI', 'poligono', '#9c6644', 3, 'dw.dm_terra_indigena', false,
 'dw.dm_terra_indigena t', 't.id, t.nome, t.etnia, round(t.area_ha, 2) AS area_ha', 'id'),
('quilombola', 'Territórios quilombolas', 'Áreas protegidas', 'INCRA', 'poligono', '#6741d9', 4, 'dw.dm_quilombola', false,
 'dw.dm_quilombola t', 't.id, t.nome, t.nu_familia, round(t.area_ha, 2) AS area_ha', 'id'),
('floresta_publica', 'Florestas públicas', 'Áreas protegidas', 'SFB', 'poligono', '#2f9e44', 6, 'dw.dm_floresta_publica', false,
 'dw.dm_floresta_publica t', 't.id, t.nome, round(t.area_ha, 2) AS area_ha', 'id'),
('area_militar', 'Áreas militares', 'Áreas protegidas', 'MD', 'poligono', '#495057', 3, 'dw.dm_area_militar', false,
 'dw.dm_area_militar t', 't.id, t.nm_area_militar AS nome, round(t.area_ha, 2) AS area_ha', 'id'),

-- no mapa: últimos 12 meses (filtro abaixo); no cruzamento com o imóvel: todos os alertas
('deter', 'Alertas DETER', 'Desmatamento', 'INPE', 'poligono', '#c92a2a', 7, 'dw.dm_deter', false,
 'dw.dm_deter t LEFT JOIN dw.ta_deter_classe c ON c.id = t.deter_classe_id',
 't.id, c.tx_descricao AS classe, t.dt_deter::text AS data, round(t.area_ha, 2) AS area_ha', 'id'),
('embargo_ibama', 'Embargos IBAMA', 'Embargos', 'IBAMA', 'poligono', '#862e9c', 7, 'dw.dm_embargo_ibama', false,
 'dw.dm_embargo_ibama t',
 't.id, t.num_auto_infracao, t.data_cadastro_tad::text AS data, t.des_infracao AS infracao, round(t.area_ha, 2) AS area_ha', 'id'),
('embargo_icmbio', 'Embargos ICMBio', 'Embargos', 'ICMBio', 'poligono', '#a61e4d', 7, 'dw.dm_embargo_icmbio', false,
 'dw.dm_embargo_icmbio t', 't.id, t.numero_embargo, t.tipo_infracao AS infracao, t.data_infracao::text AS data', 'id'),
('embargo_estadual', 'Embargos estaduais', 'Embargos', 'OEMAs', 'poligono', '#d6336c', 7, 'dw.dm_embargo_estadual', false,
 'dw.dm_embargo_estadual t',
 't.id, t.fonte, t.numero_embargo, t.tipo_infracao AS infracao, t.data_embargo::text AS data, round(t.area_ha, 2) AS area_ha', 'id'),

('minerio', 'Processos minerários', 'Mineração', 'ANM', 'poligono', '#f08c00', 8, 'dw.dm_minerio', false,
 'dw.dm_minerio t LEFT JOIN dw.ta_minerio_substancia su ON su.id = t.minerio_substancia_id
  LEFT JOIN dw.ta_minerio_fase fa ON fa.id = t.minerio_fase_id',
 't.id, t.processo, t.nome, su.tx_descricao AS substancia, fa.tx_descricao AS fase, round(t.area_ha, 2) AS area_ha', 'id'),
('reserva_garimpeira', 'Reservas garimpeiras', 'Mineração', 'ANM', 'poligono', '#e8590c', 3, 'dw.dm_reserva_garimpeira', false,
 'dw.dm_reserva_garimpeira t', 't.id, t.nome, round(t.area_ha, 2) AS area_ha', 'id'),

-- fora do cruzamento: polígonos gigantes (um por classe/município) estouram o tempo; ver ST_Subdivide
('uso_solo', 'Uso do solo', 'Uso do solo', 'MapBiomas/IBGE', 'poligono', '#94d82d', 9, NULL, false,
 'dw.dm_uso_solo t LEFT JOIN dw.ta_uso_solo_classe c ON c.id = t.uso_solo_classe_id',
 't.id, c.tx_descricao AS classe, t.ano_referencia, round(t.area_ha, 2) AS area_ha', 'id'),
('qualidade_pastagem', 'Qualidade de pastagem', 'Uso do solo', 'LAPIG', 'poligono', '#fab005', 9, 'dw.dm_qualidade_pastagem', false,
 'dw.dm_qualidade_pastagem t', 't.id, t.classe, t.ano_referencia, round(t.area_ha, 2) AS area_ha', 'id'),

('sicor_gleba', 'Glebas do crédito rural (SICOR)', 'Crédito rural', 'BACEN/SICOR', 'poligono', '#e67700', 11, 'dw.dm_sicor_gleba', false,
 'dw.dm_sicor_gleba t', 't.id, t.nr_ref_bacen, t.ano_origem, round(t.area_ha, 2) AS area_ha', 'id'),

('rodovia', 'Rodovias', 'Infraestrutura', 'DNIT', 'linha', '#343a40', 7, NULL, false,
 'dw.dm_rodovia t', 't.id, t.codigo_rodovia, t.jurisdicao, round(t.extensao_km, 1) AS extensao_km', 'id'),

('censo_2022', 'Endereços do Censo 2022', 'Censo', 'IBGE', 'ponto', '#1c7ed6', 14, NULL, false,
 'dw.dm_censo_ibge_2022 t LEFT JOIN dw.ta_censo_ibge_especie e ON e.id = t.censo_ibge_especie_id',
 't.id, e.tx_descricao AS especie', 'id');

-- DETER é temporal: por padrão só os últimos 12 meses (?data_ini=AAAA-MM-DD para outro início).
-- O filtro em "ano" deixa o PostgreSQL ler só as partições necessárias.
UPDATE camadas_dw SET p_filtro =
    $f$t.ano >= extract(year FROM coalesce((query_params->>'data_ini')::date, (now() - interval '1 year')::date))
       AND t.dt_deter >= coalesce((query_params->>'data_ini')::date, (now() - interval '1 year')::date)$f$
 WHERE id = 'deter';

DO $$
DECLARE c record;
BEGIN
    FOR c IN SELECT * FROM camadas_dw ORDER BY ordem LOOP
        CALL tiles.publicar_camada(c.id, c.p_from, c.p_atributos, c.minzoom, c.p_id_col, c.p_filtro);
    END LOOP;
END $$;

-- Focos de queimada: pontos com total por registro; agregados em células de 64 px abaixo do zoom 9.
-- Período via ?data_ini=AAAA-MM-DD&data_fim=AAAA-MM-DD (padrão: ano anterior).
CREATE OR REPLACE FUNCTION tiles.foco_queimada(z integer, x integer, y integer, query_params json)
RETURNS bytea LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    v_env      geometry := ST_TileEnvelope(z, x, y);
    v_env_4674 geometry := ST_Transform(v_env, 4674);
    v_ini      date := coalesce((query_params->>'data_ini')::date, make_date(extract(year FROM now())::int - 1, 1, 1));
    v_fim      date := coalesce((query_params->>'data_fim')::date, make_date(extract(year FROM now())::int - 1, 12, 31));
    v_mvt      bytea;
BEGIN
    IF z < 9 THEN
        SELECT ST_AsMVT(t, 'foco_queimada', 4096, 'geom') INTO v_mvt
          FROM (SELECT sum(p.qtd)::int AS qtd, ST_Centroid(ST_Collect(p.geom)) AS geom
                  FROM (SELECT coalesce(f.total_foco_queimada, 1) AS qtd,
                               ST_AsMVTGeom(ST_Transform(ST_PointOnSurface(f.geom), 3857), v_env, 4096, 0, true) AS geom
                          FROM dw.dm_foco_queimada f
                         WHERE f.geom && v_env_4674
                           AND f.ano BETWEEN extract(year FROM v_ini) AND extract(year FROM v_fim)
                           AND f.dt_foco_queimada BETWEEN v_ini AND v_fim) p
                 WHERE p.geom IS NOT NULL
                 GROUP BY ST_SnapToGrid(p.geom, 64)) t;
    ELSE
        SELECT ST_AsMVT(t, 'foco_queimada', 4096, 'geom', 'id') INTO v_mvt
          FROM (SELECT f.id, coalesce(f.total_foco_queimada, 1) AS qtd, f.dt_foco_queimada::text AS data,
                       ST_AsMVTGeom(ST_Transform(f.geom, 3857), v_env, 4096, 0, true) AS geom
                  FROM dw.dm_foco_queimada f
                 WHERE f.geom && v_env_4674
                   AND f.ano BETWEEN extract(year FROM v_ini) AND extract(year FROM v_fim)
                   AND f.dt_foco_queimada BETWEEN v_ini AND v_fim) t
         WHERE t.geom IS NOT NULL;
    END IF;
    RETURN v_mvt;
END $$;

-- Resumo por município (zoom baixo) passa a contar o CAR do dw.
DROP MATERIALIZED VIEW IF EXISTS geo.mv_municipio_resumo;
CREATE MATERIALIZED VIEW geo.mv_municipio_resumo AS
SELECT m.cod_ibge, m.nome, m.uf,
       coalesce(s.qtd_car, 0)     AS qtd_car,
       coalesce(s.area_car_ha, 0) AS area_car_ha,
       ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(m.geom, 3857), 2000))::geometry(MultiPolygon, 3857) AS geom_baixo,
       ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(m.geom, 3857), 200))::geometry(MultiPolygon, 3857) AS geom
  FROM geo.municipio m
  LEFT JOIN (SELECT municipio_id, count(*) AS qtd_car, sum(area_ha) AS area_car_ha
               FROM dw.dm_sicar GROUP BY municipio_id) s ON s.municipio_id = m.cod_ibge;
CREATE UNIQUE INDEX ON geo.mv_municipio_resumo (cod_ibge);
CREATE INDEX ON geo.mv_municipio_resumo USING gist (geom);

-- Catálogo: substitui as camadas de teste do schema geo pelas do dw.
DELETE FROM geo.camada WHERE id NOT IN ('municipio_resumo');
-- versao = instante da publicação: URLs de tile novas a cada republicação (o cache antigo nunca é servido).
INSERT INTO geo.camada (id, nome, grupo, fonte, tipo_geom, cor, minzoom, maxzoom, tabela, ativo_padrao, ordem, versao)
SELECT id, nome, grupo, fonte, tipo, cor, minzoom, 22, tabela::regclass, ativo, 100 + ordem, extract(epoch FROM now())::int
  FROM camadas_dw
UNION ALL
SELECT 'foco_queimada', 'Focos de queimada', 'Fogo', 'INPE', 'ponto', '#e8590c', 0, 22, 'dw.dm_foco_queimada'::regclass,
       false, 900, extract(epoch FROM now())::int;
UPDATE geo.camada SET maxzoom = 10, versao = extract(epoch FROM now())::int, nome = 'Imóveis CAR por município', ordem = 5
 WHERE id = 'municipio_resumo';

-- Índices para busca de imóvel na API (código por prefixo e nome aproximado).
CREATE INDEX IF NOT EXISTS idx_dm_sicar_cod_imovel_pattern ON dw.dm_sicar (cod_imovel varchar_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_dm_sicar_nome_trgm ON dw.dm_sicar USING gin (nome_imovel gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_dm_sicar_geo_sicar ON dw.dm_sicar_geo (uf_id, sicar_id);

SELECT id, minzoom, tipo_geom, tabela FROM geo.camada ORDER BY ordem;
