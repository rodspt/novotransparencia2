#!/usr/bin/env bash
# Baixa a malha municipal do IBGE e carrega em geo.municipio (base do mapa em zoom baixo).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

URL=https://geoftp.ibge.gov.br/organizacao_do_territorio/malhas_territoriais/malhas_municipais/municipio_2024/Brasil/BR_Municipios_2024.zip
mkdir -p data/ibge
[[ -f data/ibge/municipios.zip ]] || curl -fL "$URL" -o data/ibge/municipios.zip

docker run --rm --network novotransparencia_default -v "$PWD/data/ibge":/dados:ro ghcr.io/osgeo/gdal:ubuntu-small-3.11.3 \
  ogr2ogr -f PostgreSQL "PG:host=db dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD" \
    /vsizip//dados/municipios.zip -nln staging.municipio -overwrite -lco GEOMETRY_NAME=geom \
    -nlt PROMOTE_TO_MULTI -t_srs EPSG:4674 -lco PRECISION=NO

docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE geo.municipio CASCADE;
INSERT INTO geo.municipio (cod_ibge, nome, uf, geom)
SELECT cd_mun::int, nm_mun, sigla_uf, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
  FROM staging.municipio;
DROP TABLE staging.municipio;
COMMIT;
REFRESH MATERIALIZED VIEW geo.mv_municipio_resumo;
REFRESH MATERIALIZED VIEW geo.mv_brasil_mascara;
SQL
