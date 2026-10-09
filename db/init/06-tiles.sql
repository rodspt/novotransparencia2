-- Funções de vector tile (MVT) publicadas pelo Martin em /tiles/<nome>/{z}/{x}/{y}.
-- Regras:
--   * só atributos necessários para desenhar/filtrar (nada de CPF/nome: tiles ficam em cache público);
--   * filtro espacial pelo índice GIST em 4674 (envelope transformado), projeção só do que entra no tile;
--   * zoom baixo => dado agregado/simplificado, nunca a base inteira.

CREATE OR REPLACE FUNCTION tiles.sicar(z integer, x integer, y integer, query_params json)
RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH b AS (
        SELECT ST_TileEnvelope(z, x, y) AS env,
               ST_Transform(ST_TileEnvelope(z, x, y, margin => 64.0 / 4096), 4674) AS env_4674
    ), f AS (
        SELECT s.id,
               s.cod_imovel,
               s.status_imovel,
               s.tipo_imovel,
               round(s.area::numeric, 2) AS area,
               ST_AsMVTGeom(ST_Transform(s.geom, 3857), b.env, 4096, 64, true) AS geom
          FROM geo.sicar s, b
         WHERE s.geom && b.env_4674
           AND (query_params->>'uf' IS NULL OR s.uf = upper(query_params->>'uf'))
           AND (query_params->>'status' IS NULL OR s.status_imovel = query_params->>'status')
    )
    SELECT ST_AsMVT(f, 'sicar', 4096, 'geom', 'id') FROM f WHERE f.geom IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION tiles.municipio_resumo(z integer, x integer, y integer)
RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH b AS (SELECT ST_TileEnvelope(z, x, y) AS env), f AS (
        SELECT m.cod_ibge, m.nome, m.uf, m.qtd_car, round(m.area_car_ha)::bigint AS area_car_ha,
               ST_AsMVTGeom(CASE WHEN z < 6 THEN m.geom_baixo ELSE m.geom END, b.env, 4096, 64, true) AS geom
          FROM geo.mv_municipio_resumo m, b
         WHERE m.geom && b.env
    )
    SELECT ST_AsMVT(f, 'municipio_resumo', 4096, 'geom', 'cod_ibge') FROM f WHERE f.geom IS NOT NULL;
$$;

-- Período via ?data_ini=AAAA-MM-DD&data_fim=AAAA-MM-DD (padrão: últimos 30 dias).
-- Abaixo do zoom 9 os focos são agregados em células de 64 px com a contagem (atributo qtd).
CREATE OR REPLACE FUNCTION tiles.foco_queimada(z integer, x integer, y integer, query_params json)
RETURNS bytea LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    v_env      geometry := ST_TileEnvelope(z, x, y);
    v_env_4674 geometry := ST_Transform(v_env, 4674);
    v_ini      timestamptz := coalesce((query_params->>'data_ini')::timestamptz, now() - interval '30 days');
    v_fim      timestamptz := coalesce((query_params->>'data_fim')::timestamptz + interval '1 day', now());
    v_mvt      bytea;
BEGIN
    IF z < 9 THEN
        SELECT ST_AsMVT(t, 'foco_queimada', 4096, 'geom') INTO v_mvt
          FROM (SELECT count(*) AS qtd, ST_Centroid(ST_Collect(p.geom)) AS geom
                  FROM (SELECT ST_AsMVTGeom(ST_Transform(f.geom, 3857), v_env, 4096, 0, true) AS geom
                          FROM geo.foco_queimada f
                         WHERE f.geom && v_env_4674
                           AND f.data_hora >= v_ini AND f.data_hora < v_fim) p
                 WHERE p.geom IS NOT NULL
                 GROUP BY ST_SnapToGrid(p.geom, 64)) t;
    ELSE
        SELECT ST_AsMVT(t, 'foco_queimada', 4096, 'geom', 'id') INTO v_mvt
          FROM (SELECT f.id, 1 AS qtd, f.data_hora::text AS data_hora, f.satelite, f.frp, f.bioma,
                       ST_AsMVTGeom(ST_Transform(f.geom, 3857), v_env, 4096, 0, true) AS geom
                  FROM geo.foco_queimada f
                 WHERE f.geom && v_env_4674
                   AND f.data_hora >= v_ini AND f.data_hora < v_fim) t
         WHERE t.geom IS NOT NULL;
    END IF;
    RETURN v_mvt;
END $$;

CREATE OR REPLACE FUNCTION tiles.sigef(z integer, x integer, y integer, query_params json)
RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH b AS (
        SELECT ST_TileEnvelope(z, x, y) AS env,
               ST_Transform(ST_TileEnvelope(z, x, y, margin => 64.0 / 4096), 4674) AS env_4674
    ), f AS (
        SELECT s.id,
               s.qrcode,
               s.nm_area,
               st.tx_descricao AS status,
               na.tx_descricao AS natureza,
               round(s.area_ha, 2) AS area_ha,
               ST_AsMVTGeom(ST_Transform(s.geom, 3857), b.env, 4096, 64, true) AS geom
          FROM geo.sigef s
          CROSS JOIN b
          LEFT JOIN geo.sigef_status st ON st.id = s.sigef_status_id
          LEFT JOIN geo.sigef_natureza na ON na.id = s.sigef_natureza_id
         WHERE s.geom && b.env_4674
           AND (query_params->>'uf' IS NULL OR s.uf = upper(query_params->>'uf'))
    )
    SELECT ST_AsMVT(f, 'sigef', 4096, 'geom', 'id') FROM f WHERE f.geom IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION tiles.brasil_mascara(z integer, x integer, y integer)
RETURNS bytea LANGUAGE sql STABLE PARALLEL SAFE AS $$
    WITH b AS (SELECT ST_TileEnvelope(z, x, y) AS env), f AS (
        SELECT m.tipo, ST_AsMVTGeom(m.geom, b.env, 4096, 64, true) AS geom
          FROM geo.mv_brasil_mascara m, b
         WHERE m.geom && b.env
    )
    SELECT ST_AsMVT(f, 'brasil_mascara', 4096, 'geom') FROM f WHERE f.geom IS NOT NULL;
$$;
