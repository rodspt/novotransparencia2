#!/usr/bin/env bash
# Gera imóveis FICTÍCIOS do CAR para desenvolvimento (requer etl/importar_municipios.sh antes).
#
#   ./etl/gerar_exemplos.sh                     # UFs padrão, 8 municípios x 60 imóveis cada
#   ./etl/gerar_exemplos.sh "MT PA" 20 100      # UFs, municípios por UF, imóveis por município
#   ./etl/gerar_exemplos.sh remover             # apaga todos os fictícios (id >= 900000000)
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

UFS=${1:-"MT PA GO BA MG RS DF"}
MUNICIPIOS=${2:-8}
POR_MUNICIPIO=${3:-60}

psql_db() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"; }

psql_db -q < db/exemplos/imoveis_exemplo.sql

if [[ $UFS == remover ]]; then
  psql_db -c "CALL geo.remover_imoveis_exemplo();"
else
  for UF in $UFS; do
    echo ">> $UF"
    psql_db -c "CALL geo.gerar_imoveis_exemplo('$UF', $MUNICIPIOS, $POR_MUNICIPIO);"
  done
fi

psql_db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY geo.mv_municipio_resumo;" \
        -c "UPDATE geo.camada SET versao = versao + 1, atualizado_em = now() WHERE id IN ('sicar', 'municipio_resumo');" \
        -c "SELECT uf, count(*) AS imoveis, round(avg(area)) AS area_media_ha FROM geo.sicar GROUP BY uf ORDER BY uf;"
