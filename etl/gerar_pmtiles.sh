#!/usr/bin/env bash
# Para camadas grandes que mudam pouco (glebas, assentamentos, terras indígenas, área militar,
# PRODES consolidado...): exporta do PostGIS e pré-gera um .pmtiles com tippecanoe.
# O Martin publica automaticamente data/pmtiles/<camada>.pmtiles em /tiles/<camada>/{z}/{x}/{y}
# (reiniciar o martin); depois cadastre a camada em geo.camada.
#
#   ./etl/gerar_pmtiles.sh assentamento "SELECT id, nome, uf, geom FROM geo.assentamento"
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

CAMADA=$1
SQL=$2
mkdir -p data/export data/pmtiles

docker run --rm --network novotransparencia_default -v "$PWD/data/export":/out ghcr.io/osgeo/gdal:ubuntu-small-3.11.3 \
  ogr2ogr -f FlatGeobuf "/out/$CAMADA.fgb" \
    "PG:host=db dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD" \
    -sql "$SQL" -t_srs EPSG:4326 -overwrite

# Imagem do tippecanoe construída a partir do repositório oficial (felt/tippecanoe).
docker image inspect tippecanoe >/dev/null 2>&1 || docker build -t tippecanoe https://github.com/felt/tippecanoe.git
docker run --rm -v "$PWD/data":/data tippecanoe \
  tippecanoe -o "/data/pmtiles/$CAMADA.pmtiles" -l "$CAMADA" --force \
    -zg --drop-densest-as-needed --extend-zooms-if-still-dropping --coalesce-densest-as-needed \
    "/data/export/$CAMADA.fgb"
