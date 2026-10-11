#!/usr/bin/env bash
# Migra o schema dw do banco legado para o banco novo, pela rede, de forma retomável.
# A origem só é lida, com 1 conexão. Tabelas grandes sem partição na origem são criadas
# particionadas aqui (ver etl/migrar_dw/particionar.sql).
#
#   export PG_ORIGEM="postgresql://usuario:senha@host:5432/banco"
#   ./etl/migrar_dw.sh esquema     # estrutura sem índices + particionamento + lista de tabelas
#   ./etl/migrar_dw.sh dados       # copia em blocos; pode ser interrompido e rodado de novo
#   ./etl/migrar_dw.sh finalizar   # índices, PKs, FKs, views, sequências, ANALYZE
#   ./etl/migrar_dw.sh camadas     # publica as tabelas do dw no mapa (tiles + catálogo + Martin)
#   ./etl/migrar_dw.sh status
#   ./etl/migrar_dw.sh parar       # encerra com segurança ao fim do bloco atual
#   ./etl/migrar_dw.sh ignorar <tabela>   # tira a tabela da cópia
#
# Rodar em segundo plano:  nohup setsid ./etl/migrar_dw.sh tudo > data/migracao_dw.log 2>&1 &
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

ETAPA=${1:-status}
BLOCO_MB=${BLOCO_MB:-200}        # volume alvo por bloco; páginas por bloco são calculadas por tabela
MAX_TENTATIVAS=${MAX_TENTATIVAS:-10}
DIR=data/dump
IMAGEM=postgis/postgis:17-3.5
PARAR="$DIR/PARAR"
mkdir -p "$DIR"

local_psql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -q "$@"; }
log() { echo "[$(date '+%F %T')] $*"; }

origem_url() {
  : "${PG_ORIGEM:?defina PG_ORIGEM com a URL de conexão do banco de origem}"
  # Parâmetros só desta sessão (não alteram o servidor): identificação e keepalive, para uma
  # queda de rede não deixar sessão órfã presa na origem.
  local sep='?'; [[ $PG_ORIGEM == *\?* ]] && sep='&'
  echo "${PG_ORIGEM}${sep}application_name=migracao_dw&keepalives=1&keepalives_idle=30&keepalives_interval=10&keepalives_count=6&tcp_user_timeout=120000&options=-c%20tcp_keepalives_idle%3D30%20-c%20tcp_keepalives_interval%3D10%20-c%20tcp_keepalives_count%3D6%20-c%20tcp_user_timeout%3D120000"
}

origem_psql() { docker run --rm -e URL="$(origem_url)" $IMAGEM sh -c 'psql "$URL" -X -v ON_ERROR_STOP=1 -q "$@"' -- "$@"; }

etapa_esquema() {
  if [[ $(local_psql -Atc "SELECT count(*) FROM pg_tables WHERE schemaname = 'dw'") != 0 ]]; then
    log "schema dw já existe no banco novo; pulando criação da estrutura"
  else
    log "lendo estrutura do dw na origem (pg_dump --schema-only)"
    docker run --rm -v "$PWD/$DIR":/dump -e URL="$(origem_url)" $IMAGEM \
      sh -c 'pg_dump --dbname="$URL" --schema=dw --schema-only --format=custom --no-owner --no-privileges -f /dump/dw_esquema.dump'
    docker run --rm -v "$PWD/$DIR":/dump $IMAGEM sh -c '
      pg_restore -l /dump/dw_esquema.dump > /dump/dw_esquema.lista
      grep -E " (VIEW|MATERIALIZED VIEW) "  /dump/dw_esquema.lista > /dump/dw_views.lista || true
      grep -vE " (VIEW|MATERIALIZED VIEW) " /dump/dw_esquema.lista > /dump/dw_pre.lista'
    log "criando tabelas (sem índices/constraints; views ficam para o final)"
    docker run --rm --network novotransparencia_default -v "$PWD/$DIR":/dump -e PGPASSWORD="$POSTGRES_PASSWORD" $IMAGEM \
      pg_restore --host=db --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --section=pre-data \
                 --no-owner --no-privileges -L /dump/dw_pre.lista /dump/dw_esquema.dump 2> "$DIR/pre.erros" || true
    [[ -s $DIR/pre.erros ]] && { log "avisos do pre-data:"; grep -E 'error|ERRO' "$DIR/pre.erros" | head -20; }
  fi

  log "particionando tabelas (plano em etl/migrar_dw/particionar.sql)"
  local_psql < etl/migrar_dw/particionar.sql
  while IFS='|' read -r t c a <&3; do
    local_psql -c "CALL migracao.particionar('$t', '$c', '$a')"
  done 3< <(local_psql -Atc "SELECT tabela, chave, add_uf FROM migracao.plano_particao ORDER BY 1")

  log "registrando tabelas a copiar"
  origem_psql -At -F '|' -c "
    SELECT c.relname, c.relname, pg_relation_size(c.oid) / 8192, pg_table_size(c.oid),
           EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
                    WHERE a.attrelid = c.oid AND t.typname = 'geometry' AND NOT a.attisdropped)
      FROM pg_class c
     WHERE c.relnamespace = 'dw'::regnamespace AND c.relkind = 'r'" \
  | local_psql -c "\copy migracao.copia (tabela, destino, blocos, bytes_total, geo) FROM STDIN (FORMAT csv, DELIMITER '|')" 2>/dev/null \
  || log "lista de tabelas já registrada"
  etapa_status
}

copiar_tabela() {
  local t=$1 blocos=$2 atual=$3 paginas=$4 fim bytes tentativas=0
  if [[ $(local_psql -Atc "SELECT status FROM migracao.copia WHERE tabela = '$t'") == ignorada ]]; then
    log "$t: ignorada"; return 0
  fi
  log "$t: $atual/$blocos páginas ($paginas por bloco)"
  while (( atual < blocos )); do
    if [[ -e $PARAR ]]; then log "parada solicitada; encerrando antes do próximo bloco"; exit 3; fi
    fim=$(( atual + paginas ))
    if bytes=$(docker compose exec -T -e PG_ORIGEM="$(origem_url)" db bash -s -- "$t" "$atual" "$fim" < etl/migrar_dw/bloco.sh 2> "$DIR/bloco.erro" | tail -1); then
      atual=$fim; tentativas=0
      log "$t: até página $(( atual < blocos ? atual : blocos ))/$blocos (+$(( bytes / 1048576 )) MB)"
    else
      tentativas=$(( tentativas + 1 ))
      local erro; erro=$(tail -c 500 "$DIR/bloco.erro" | tr '\n' ' ' | tr "'" '"')
      local_psql -c "UPDATE migracao.copia SET tentativas = tentativas + 1, erro = '$erro', atualizado = now() WHERE tabela = '$t'"
      if (( tentativas >= MAX_TENTATIVAS )); then
        log "$t: desistindo após $tentativas tentativas: $erro"
        local_psql -c "UPDATE migracao.copia SET status = 'erro' WHERE tabela = '$t'"
        return 0
      fi
      log "$t: falha (tentativa $tentativas), aguardando $(( 60 * tentativas )) s: $erro"
      sleep $(( 60 * tentativas ))
    fi
  done
  local_psql -c "UPDATE migracao.copia SET status = 'concluida', atualizado = now() WHERE tabela = '$t'"
}

etapa_dados() {
  rm -f "$PARAR"
  local_psql < etl/migrar_dw/particionar.sql
  if [[ $(local_psql -Atc "SELECT count(*) FROM migracao.copia WHERE bytes_total IS NULL") != 0 ]]; then
    log "lendo tamanho real (com TOAST) das tabelas na origem"
    origem_psql -At -F '|' -c "SELECT c.relname, pg_table_size(c.oid) FROM pg_class c
                                WHERE c.relnamespace = 'dw'::regnamespace AND c.relkind = 'r'" \
    > "$DIR/tamanhos.txt"
    local_psql -c "CREATE TABLE IF NOT EXISTS migracao.tamanho (tabela text, bytes bigint); TRUNCATE migracao.tamanho;"
    local_psql -c "\copy migracao.tamanho FROM STDIN (FORMAT csv, DELIMITER '|')" < "$DIR/tamanhos.txt"
    local_psql -c "UPDATE migracao.copia c SET bytes_total = t.bytes FROM migracao.tamanho t WHERE t.tabela = c.tabela;
                   DROP TABLE migracao.tamanho;"
  fi
  log "copiando dados (blocos de ~$BLOCO_MB MB; geográficas primeiro)"
  # tabelas com erro voltam para a fila numa nova execução
  local_psql -c "UPDATE migracao.copia SET status = 'copiando', tentativas = 0 WHERE status = 'erro'"
  # páginas por bloco = proporcional ao tamanho real da tabela (MapBiomas: ~0,8 MB por página!)
  local_psql -At -F ' ' -c "SELECT tabela, blocos, bloco_atual,
                                   greatest(1, least(25000, ($BLOCO_MB * 1048576.0 * blocos / nullif(bytes_total, 0))::bigint))
                              FROM migracao.copia
                             WHERE status NOT IN ('concluida', 'ignorada') ORDER BY geo DESC, bytes_total" > "$DIR/fila.txt"
  while read -r t blocos atual paginas <&3; do
    copiar_tabela "$t" "$blocos" "$atual" "${paginas:-25000}"
  done 3< "$DIR/fila.txt"
  etapa_status
}

etapa_finalizar() {
  if [[ $(local_psql -Atc "SELECT count(*) FROM migracao.copia WHERE status NOT IN ('concluida', 'ignorada')") != 0 ]]; then
    log "ainda há tabelas não concluídas; rode a etapa dados antes"; etapa_status; return 1
  fi
  log "gerando índices/constraints adaptados ao particionamento"
  docker run --rm -v "$PWD/$DIR":/dump $IMAGEM pg_restore --section=post-data -f /dump/post.sql /dump/dw_esquema.dump
  local_psql -Atc "SELECT tabela || '|' || chave FROM migracao.plano_particao" > "$DIR/plano.txt"
  python3 etl/migrar_dw/pos_dados.py "$DIR/post.sql" "$DIR/plano.txt" > "$DIR/post_ajustado.sql" 2> "$DIR/post_ignorados.sql"
  log "criando índices e constraints (pode levar horas)"
  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q < "$DIR/post_ajustado.sql" 2> "$DIR/post.erros" || true

  log "criando views"
  docker run --rm --network novotransparencia_default -v "$PWD/$DIR":/dump -e PGPASSWORD="$POSTGRES_PASSWORD" $IMAGEM \
    pg_restore --host=db --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-owner --no-privileges \
               -L /dump/dw_views.lista /dump/dw_esquema.dump 2> "$DIR/views.erros" || true

  log "ajustando sequências e atualizando estatísticas"
  local_psql <<'SQL'
DO $$
DECLARE r record; v bigint;
BEGIN
  FOR r IN SELECT c.oid::regclass AS tabela, a.attname, pg_get_serial_sequence(c.oid::regclass::text, a.attname) AS seq
             FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            WHERE c.relnamespace = 'dw'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
              AND pg_get_serial_sequence(c.oid::regclass::text, a.attname) IS NOT NULL
  LOOP
    EXECUTE format('SELECT max(%I) FROM %s', r.attname, r.tabela) INTO v;
    IF v IS NOT NULL THEN PERFORM setval(r.seq, v); END IF;
  END LOOP;
END $$;
ANALYZE;
SQL
  log "erros de índices/constraints: $(grep -c ERROR "$DIR/post.erros" || true) (detalhes em $DIR/post.erros)"
  log "itens adaptados/ignorados: $DIR/post_ignorados.sql"
  log "erros de views: $(grep -c 'error' "$DIR/views.erros" || true) (detalhes em $DIR/views.erros)"
}

etapa_camadas() {
  log "publicando camadas do dw (etl/migrar_dw/camadas.sql)"
  local_psql < etl/migrar_dw/camadas.sql
  local ids; ids=$(local_psql -Atc "SELECT string_agg(id, ' ' ORDER BY ordem) FROM geo.camada")
  python3 - "$ids brasil_mascara" <<'PY'
import sys
ids = sys.argv[1].split()
p = 'martin/martin.yaml'
s = open(p).read()
ini = s.index("  # Gerado a partir de geo.camada"); fim = s.index("\n# Camadas estáticas")
corpo = "  # Gerado a partir de geo.camada (zoom mínimo real é controlado pela função e pelo mapa).\n  functions:\n" + "".join(
    f"    {i}:\n      schema: tiles\n      function: {i}\n      minzoom: 0\n      maxzoom: 22\n" for i in ids)
open(p, 'w').write(s[:ini] + corpo + s[fim:])
PY
  docker compose restart martin >/dev/null
  log "$(wc -w <<< "$ids") camadas publicadas"
}

etapa_status() {
  local_psql -c "
    SELECT status, count(*) AS tabelas,
           pg_size_pretty(sum(blocos) * 8192) AS volume_origem,
           pg_size_pretty(sum(least(bloco_atual, blocos)) * 8192) AS copiado,
           round(100.0 * sum(least(bloco_atual, blocos)) / nullif(sum(blocos), 0), 1) AS pct
      FROM migracao.copia GROUP BY ROLLUP (status) ORDER BY status NULLS LAST;"
  local_psql -c "SELECT tabela, status, tentativas, left(erro, 120) AS erro FROM migracao.copia WHERE status = 'erro'"
}

case $ETAPA in
  esquema)   etapa_esquema ;;
  dados)     etapa_dados ;;
  finalizar) etapa_finalizar ;;
  camadas)   etapa_camadas ;;
  status)    etapa_status ;;
  parar)     touch "$PARAR"; log "o processo vai parar ao fim do bloco atual" ;;
  ignorar)   local_psql -c "UPDATE migracao.copia SET status = 'ignorada', atualizado = now() WHERE tabela = '${2:?informe a tabela}'" ;;
  tudo)      etapa_esquema && etapa_dados && etapa_finalizar && etapa_camadas ;;
  *) echo "etapa inválida: $ETAPA"; exit 1 ;;
esac
