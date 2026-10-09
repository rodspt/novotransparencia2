#!/usr/bin/env bash
# Copia dw.dm_sigef do banco legado para geo.sigef, UF por UF (a origem só é lida).
# Em dw.dm_sigef o uf_id está vazio: a UF sai da faixa do código IBGE do município (DF = 53xxxxx).
#
#   PG_ORIGEM="postgresql://usuario:senha@host:5432/banco" ./etl/copiar_sigef_banco.sh "DF GO"
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

: "${PG_ORIGEM:?defina PG_ORIGEM com a URL de conexão do banco de origem}"
UFS=${1:?informe as UFs, ex.: \"DF GO\"}
COLUNAS="id, qrcode, nm_area, sncr, rt, art, registro_matricula, dt_registro_matricula, dt_submissao, dt_aprovacao, area_ha, sigef_status_id, sigef_natureza_id, modulo_fiscal, modulo_fiscal_id, municipio_id, geom, dt_inclusao"

local_psql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q "$@"; }
origem_para_local() {  # $1 = SELECT na origem, $2 = tabela local (colunas)
  docker compose exec -T -e PG_ORIGEM="$PG_ORIGEM" -e ORIGEM_SQL="$1" -e DESTINO="$2" db bash -euo pipefail -c '
    psql "$PG_ORIGEM" -v ON_ERROR_STOP=1 -c "\copy ($ORIGEM_SQL) TO STDOUT (FORMAT binary)" \
      | psql -U $POSTGRES_USER -d $POSTGRES_DB -v ON_ERROR_STOP=1 -q -c "\copy $DESTINO FROM STDIN (FORMAT binary)"'
}

echo ">> domínios (status e natureza)"
for T in status natureza; do
  local_psql -c "CREATE TABLE IF NOT EXISTS staging.sigef_$T (id int, tx_descricao text); TRUNCATE staging.sigef_$T;"
  origem_para_local "SELECT id, tx_descricao::text FROM dw.ta_sigef_$T" "staging.sigef_$T (id, tx_descricao)"
  local_psql -c "INSERT INTO geo.sigef_$T SELECT * FROM staging.sigef_$T
                 ON CONFLICT (id) DO UPDATE SET tx_descricao = EXCLUDED.tx_descricao; DROP TABLE staging.sigef_$T;"
done

for UF in $UFS; do
  UF=$(echo "$UF" | tr '[:lower:]' '[:upper:]'); uf=$(echo "$UF" | tr '[:upper:]' '[:lower:]')
  CD=$(local_psql -Atc "SELECT cd_uf FROM geo.uf WHERE sigla_uf = '$UF'")
  inicio=$SECONDS
  echo ">> $UF (municípios ${CD}00000-${CD}99999)"
  local_psql -c "DROP TABLE IF EXISTS staging.sigef_$uf;
                 CREATE UNLOGGED TABLE staging.sigef_$uf (
                   id int, qrcode varchar(36), nm_area text, sncr varchar(13), rt text, art text,
                   registro_matricula text, dt_registro_matricula date, dt_submissao date, dt_aprovacao date,
                   area_ha numeric(20,4), sigef_status_id int, sigef_natureza_id int, modulo_fiscal numeric,
                   modulo_fiscal_id int, municipio_id int, geom geometry, dt_inclusao timestamp);"
  origem_para_local \
    "SELECT $COLUNAS FROM dw.dm_sigef WHERE municipio_id BETWEEN ${CD}00000 AND ${CD}99999" \
    "staging.sigef_$uf ($COLUNAS)"
  local_psql -c "CALL geo.carregar_sigef_uf('$UF');"
  local_psql -Atc "SELECT '   ' || count(*) || ' parcelas em geo.sigef_$uf (' || ($SECONDS - $inicio) || ' s)' FROM geo.sigef_$uf"
done
