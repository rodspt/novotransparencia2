#!/usr/bin/env bash
# Carrega o SICAR de UMA UF e troca a partição sem derrubar o mapa.
#
#   ./etl/importar_sicar.sh DF "PG:host=servidor-antigo dbname=x user=y password=z"   # do banco atual (sa.sicar)
#   ./etl/importar_sicar.sh DF /caminho/sicar_df.gpkg                                   # de arquivo (shp/gpkg/geojson)
#
# Rodar UF por UF (dá para paralelizar entre UFs diferentes).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

UF=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ORIGEM=$2
REDE=novotransparencia_default
DESTINO="PG:host=db dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD"

SQL_ARG=()
if [[ $ORIGEM == PG:* ]]; then
  SQL_ARG=(-sql "SELECT * FROM sa.sicar WHERE uf = '${UF^^}'")
  MONTAGEM=()
else
  MONTAGEM=(-v "$(realpath "$(dirname "$ORIGEM")")":/dados:ro)
  ORIGEM=/dados/$(basename "$ORIGEM")
fi

echo ">> staging.sicar_$UF"
docker run --rm --network "$REDE" "${MONTAGEM[@]}" ghcr.io/osgeo/gdal:ubuntu-small-3.11.3 \
  ogr2ogr -f PostgreSQL "$DESTINO" "$ORIGEM" "${SQL_ARG[@]}" \
    -nln "staging.sicar_$UF" -overwrite -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE \
    -lco FID=ogc_fid -nlt PROMOTE_TO_MULTI -a_srs EPSG:4674 --config PG_USE_COPY YES -progress

echo ">> normalizando e trocando a partição geo.sicar_$UF"
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "CALL geo.carregar_sicar_uf('$UF');" \
  -c "REFRESH MATERIALIZED VIEW CONCURRENTLY geo.mv_municipio_resumo;"
echo ">> ok"
