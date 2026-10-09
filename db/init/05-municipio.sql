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
