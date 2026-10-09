#!/usr/bin/env bash
# Copia sa.sicar de outro PostgreSQL para geo.sicar, UF por UF, via COPY em streaming
# (origem -> staging.sicar_<uf> -> geo.carregar_sicar_uf). A origem só é lida.
#
#   PG_ORIGEM="postgresql://usuario:senha@host:5432/banco" ./etl/copiar_sicar_banco.sh          # todas as UFs
#   PG_ORIGEM="..." ./etl/copiar_sicar_banco.sh "DF GO MT"                                        # algumas
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

: "${PG_ORIGEM:?defina PG_ORIGEM com a URL de conexão do banco de origem}"
UFS=${1:-$(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT string_agg(sigla_uf, ' ' ORDER BY sigla_uf) FROM geo.uf")}
COLUNAS="id, cod_imovel, status_imovel, dat_criacao, area, condicao, uf, municipio, cod_municipio_ibge, m_fiscal, tipo_imovel, nome_imovel, cpf_cnpj_proprietario, nome_proprietario, geom, dt_inclusao"

for UF in $UFS; do
  uf=$(echo "$UF" | tr '[:upper:]' '[:lower:]')
  UF=$(echo "$UF" | tr '[:lower:]' '[:upper:]')
  inicio=$SECONDS
  echo ">> $UF"
  docker compose exec -T -e PG_ORIGEM="$PG_ORIGEM" -e UF="$UF" -e uf="$uf" -e COLUNAS="$COLUNAS" db bash -euo pipefail -c '
    DESTINO="psql -U $POSTGRES_USER -d $POSTGRES_DB -v ON_ERROR_STOP=1 -q"
    $DESTINO -c "DROP TABLE IF EXISTS staging.sicar_$uf;
                 CREATE UNLOGGED TABLE staging.sicar_$uf (LIKE geo.sicar INCLUDING DEFAULTS);
                 ALTER TABLE staging.sicar_$uf ALTER COLUMN geom TYPE geometry, ALTER COLUMN uf TYPE text;"
    psql "$PG_ORIGEM" -v ON_ERROR_STOP=1 -c "\copy (SELECT $COLUNAS FROM sa.sicar WHERE upper(trim(uf)) = '"'"'$UF'"'"') TO STDOUT" \
      | $DESTINO -c "\copy staging.sicar_$uf ($COLUNAS) FROM STDIN"
    $DESTINO -c "CALL geo.carregar_sicar_uf('"'"'$UF'"'"');"
  '
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
    "SELECT '   ' || count(*) || ' imóveis em geo.sicar_$uf (' || ($SECONDS - $inicio) || ' s)' FROM geo.sicar_$uf"
done

docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q \
  -c "REFRESH MATERIALIZED VIEW CONCURRENTLY geo.mv_municipio_resumo;" \
  -c "UPDATE geo.camada SET versao = versao + 1, atualizado_em = now() WHERE id = 'municipio_resumo';"
echo ">> concluído"
