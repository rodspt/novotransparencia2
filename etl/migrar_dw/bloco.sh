#!/usr/bin/env bash
# Copia UM bloco de páginas (ctid) de dw.<tabela> da origem para o banco novo.
# Executado dentro do container db:  docker compose exec -T -e PG_ORIGEM db bash -s -- <tabela> <ini> <fim> < bloco.sh
# O bloco vai primeiro para um arquivo; só é gravado (junto com o progresso, na mesma transação)
# se a leitura terminou sem erro. Assim uma queda de rede nunca deixa dado pela metade.
set -euo pipefail
T=$1; INI=$2; FIM=$3
ARQ=/tmp/migracao_bloco.bin
LOCAL=(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -q)

IFS='|' read -r COLS_DESTINO COLS_ORIGEM < <("${LOCAL[@]}" -At -c "SELECT destino, origem FROM migracao.colunas('$T')")

rm -f "$ARQ"
rc=0
timeout 1800 psql "$PG_ORIGEM" -X -v ON_ERROR_STOP=1 -q -c \
  "\copy (SELECT $COLS_ORIGEM FROM dw.\"$T\" WHERE ctid >= '($INI,0)'::tid AND ctid < '($FIM,0)'::tid) TO '$ARQ' (FORMAT binary)" || rc=$?
if (( rc == 124 )); then echo "timeout: bloco $INI-$FIM passou de 30 min" >&2; exit 1; fi
(( rc == 0 )) || exit "$rc"
BYTES=$(stat -c%s "$ARQ")

"${LOCAL[@]}" <<SQL
BEGIN;
\copy dw."$T" ($COLS_DESTINO) FROM '$ARQ' (FORMAT binary)
UPDATE migracao.copia SET bloco_atual = $FIM, bytes = bytes + $BYTES, status = CASE WHEN status = 'ignorada' THEN status ELSE 'copiando' END, erro = NULL, atualizado = now()
 WHERE tabela = '$T';
COMMIT;
SQL
rm -f "$ARQ"
echo "$BYTES"
