#!/usr/bin/env bash
# Copia o schema dw (estrutura + dados + índices) do banco legado para o banco novo.
# Na origem só há leitura: pg_dump usa um snapshot consistente e não altera nada.
#
#   PG_ORIGEM="postgresql://usuario:senha@host:5432/banco" ./etl/copiar_schema_dw.sh [dump|restore|tudo]
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

ETAPA=${1:-tudo}
JOBS=${JOBS:-6}
IMAGEM=postgis/postgis:17-3.5
DUMP=data/dump/dw
mkdir -p data/dump

if [[ $ETAPA == dump || $ETAPA == tudo ]]; then
  : "${PG_ORIGEM:?defina PG_ORIGEM com a URL de conexão do banco de origem}"
  rm -rf "$DUMP"
  echo ">> pg_dump (origem, somente leitura) -> $DUMP"
  docker run --rm -v "$PWD/data/dump":/dump -e PG_ORIGEM="$PG_ORIGEM" $IMAGEM \
    sh -c "pg_dump --dbname=\"\$PG_ORIGEM\" --schema=dw --format=directory --jobs=$JOBS \
           --compress=lz4 --no-owner --no-privileges --verbose --file=/dump/dw" > data/dump/dump.log 2>&1
  grep -iE 'error|erro' data/dump/dump.log || true
  du -sh "$DUMP"
fi

if [[ $ETAPA == restore || $ETAPA == tudo ]]; then
  echo ">> pg_restore -> banco novo"
  docker run --rm --network novotransparencia_default -v "$PWD/data/dump":/dump \
    -e PGPASSWORD="$POSTGRES_PASSWORD" $IMAGEM \
    sh -c "pg_restore --host=db --username=$POSTGRES_USER --dbname=$POSTGRES_DB --jobs=$JOBS \
           --no-owner --no-privileges --verbose /dump/dw" > data/dump/restore.log 2>&1 || true
  echo ">> erros do restore (log completo em data/dump/restore.log):"
  grep -A2 -E 'error:' data/dump/restore.log || echo '   nenhum'
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ANALYZE;" >/dev/null
fi
