-- Malha municipal do IBGE (etl/importar_municipios.sh). Usada para o mapa em zoom baixo:
-- ninguém consegue ler 7 milhões de polígonos do CAR vendo o Brasil inteiro, então até o
-- zoom 8 o mapa mostra um coroplético por município e só depois o polígono de cada imóvel.
CREATE TABLE geo.municipio (
    cod_ibge int PRIMARY KEY,
    nome     text NOT NULL,
    uf       char(2) NOT NULL REFERENCES geo.uf,
    geom     geometry(MultiPolygon, 4674) NOT NULL
);
CREATE INDEX ON geo.municipio USING gist (geom);
CREATE INDEX ON geo.municipio (uf);

-- Geometria já simplificada e em 3857: tiles de zoom baixo saem sem custo de projeção.
-- Atualizar após cargas: REFRESH MATERIALIZED VIEW CONCURRENTLY geo.mv_municipio_resumo;
CREATE MATERIALIZED VIEW geo.mv_municipio_resumo AS
SELECT m.cod_ibge,
       m.nome,
       m.uf,
       coalesce(s.qtd_car, 0)     AS qtd_car,
       coalesce(s.area_car_ha, 0) AS area_car_ha,
       -- duas resoluções: ~2 km para zoom < 6 (Brasil/região) e ~200 m para zoom 6-8
       ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(m.geom, 3857), 2000))::geometry(MultiPolygon, 3857) AS geom_baixo,
       ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(m.geom, 3857), 200))::geometry(MultiPolygon, 3857) AS geom
  FROM geo.municipio m
  LEFT JOIN (
        SELECT cod_municipio_ibge, count(*) AS qtd_car, sum(area) AS area_car_ha
          FROM geo.sicar
         GROUP BY cod_municipio_ibge
  ) s ON s.cod_municipio_ibge = m.cod_ibge;

CREATE UNIQUE INDEX ON geo.mv_municipio_resumo (cod_ibge);
CREATE INDEX ON geo.mv_municipio_resumo USING gist (geom);

-- Máscara "só Brasil": mundo menos o contorno do país (união dos municípios), para cobrir
-- os países vizinhos no mapa base. Subdividida em pedaços pequenos para os tiles saírem rápidos.
-- Atualizar após importar os municípios: REFRESH MATERIALIZED VIEW geo.mv_brasil_mascara;
CREATE MATERIALIZED VIEW geo.mv_brasil_mascara AS
WITH uniao AS (
    SELECT ST_Union(geom) AS geom FROM geo.municipio
), brasil AS (
    -- só os anéis externos: elimina frestas entre municípios vizinhos (o Brasil não tem enclaves)
    SELECT ST_Transform(ST_Collect(ST_MakePolygon(ST_ExteriorRing(d.geom))), 3857) AS geom
      FROM uniao, ST_Dump(uniao.geom) d
)
SELECT 'mascara'::text AS tipo,
       ST_Subdivide(ST_Difference(ST_Transform(ST_MakeEnvelope(-180, -85.05, 180, 85.05, 4326), 3857), brasil.geom), 512) AS geom
  FROM brasil
UNION ALL
SELECT 'contorno', ST_Subdivide(ST_Boundary(brasil.geom), 512)
  FROM brasil;

CREATE INDEX ON geo.mv_brasil_mascara USING gist (geom);
