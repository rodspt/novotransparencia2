# Novo Transparência

Mapa de bases fundiárias e ambientais de propriedades rurais do Brasil (SICAR, SIGEF, PRODES, DETER,
embargos, focos de queimada, MapBiomas, glebas, assentamentos...), pensado para terabytes de geometria.

## Por que não Leaflet + GeoJSON

Leaflet + GeoJSON manda geometria completa para o navegador e desenha em SVG/Canvas: trava com
algumas dezenas de milhares de polígonos. Aqui o navegador **nunca recebe a base**, recebe
**vector tiles** (MVT): pedaços de 256 px já recortados, simplificados e compactados para o zoom
atual, desenhados em WebGL pelo MapLibre. O custo por tela fica constante, seja DF ou Brasil inteiro.

## Arquitetura

```
navegador ──► gateway (nginx :8080)
                ├─ /         ► web     Next.js 15 + MapLibre GL (WebGL)
                ├─ /api/     ► api     FastAPI: atributos, busca, sobreposições
                └─ /tiles/   ► martin  servidor de vector tiles (Rust)  ──┐
                     └─ cache em disco no nginx (1 tile = 1 consulta, só na 1ª vez)
                                                                          ▼
                                               db  PostgreSQL 17 + PostGIS 3.5
```

| Peça | Escolha | Motivo |
|---|---|---|
| Banco | PostgreSQL + PostGIS | `ST_AsMVT` gera os tiles no próprio banco; particionamento nativo |
| Tiles | [Martin](https://maplibre.org/martin/) | publica funções `tiles.*` do PostGIS e arquivos `.pmtiles` |
| Cache | nginx `proxy_cache` | tiles quentes nem chegam ao banco; `?v=` invalida após carga |
| Mapa | MapLibre GL JS | WebGL, milhões de feições na tela, estilo dinâmico, *feature-state* |
| Front | Next.js | pedido do projeto; o mapa roda só no cliente |
| API | FastAPI + asyncpg | leve, assíncrona, ecossistema geo do Python para ETL |

## Estratégia de dados

**Particionamento — depende do tipo da base:**

- *Cadastrais* (SICAR, SIGEF, glebas, assentamentos, embargos): `PARTITION BY LIST (uf)`. Cada
  UF é recarregada isoladamente: carga em tabela nova → índices → troca da partição
  (`geo.substituir_particao_uf`). O mapa não fica fora do ar durante a carga.
- *Temporais* (focos de queimada, DETER, PRODES, área queimada): `PARTITION BY RANGE (data)`,
  porque são consultadas por período e crescem no tempo.
- Todas têm `uf char(2) NOT NULL REFERENCES geo.uf`.

**Apresentação por zoom — nunca mostrar a base inteira:**

| Zoom | SICAR | Focos |
|---|---|---|
| 0–8 | coroplético por município (`mv_municipio_resumo`, geometria pré-simplificada) | agregados em células de 64 px com contagem |
| 9+ | polígono de cada imóvel | cada foco |
| 15+ | overzoom do tile z14 (sem novas requisições) | idem |

**Outras regras:**

- Geometria tipada e em SIRGAS 2000 (`geometry(MultiPolygon, 4674)`), validada na carga
  (`ST_MakeValid`) e gravada em ordem espacial (geohash) para cada tile ler poucas páginas de disco.
- Tiles levam só atributos de desenho/filtro. **CPF/CNPJ e nome do proprietário nunca vão para o
  tile** (fica em cache público); a API devolve mascarado, salvo `EXPOR_DADOS_PESSOAIS=true`.
- Bases grandes que mudam pouco (glebas, assentamentos, terras indígenas, área militar, PRODES
  consolidado): pré-gerar `.pmtiles` com tippecanoe (`etl/gerar_pmtiles.sh`). Servido como arquivo,
  custo zero no banco.
- MapBiomas cobertura/uso é **raster**: servir como COG + TiTiler (ou tiles raster pré-gerados),
  não vetorizar.

## Rodando

```bash
cp .env.example .env              # ajuste senha e memória do Postgres
docker compose up -d --build
./etl/importar_municipios.sh      # malha do IBGE (necessária para o zoom baixo)
```

Acesse http://localhost:8080. Os scripts de `db/init` rodam só na criação do volume
(`docker compose down -v` apaga o banco).

## Carregando dados

```bash
# SICAR por UF, a partir do banco atual (tabela sa.sicar) ou de arquivo shp/gpkg
./etl/importar_sicar.sh DF "PG:host=IP dbname=BANCO user=USUARIO password=SENHA"
./etl/importar_sicar.sh MT /dados/sicar_mt.gpkg
```

Cada carga incrementa `geo.camada.versao`; o front passa a pedir `?v=<nova versão>` e o cache
antigo expira sozinho.

## Adicionando uma camada (ex.: SIGEF)

1. `db/init`: tabela `geo.sigef` no molde de `geo.sicar` (particionada por UF, FK para `geo.uf`,
   índice GIST) + procedimento de carga.
2. `db/init/06-tiles.sql`: função `tiles.sigef(z, x, y, query_params)` copiando `tiles.sicar`.
3. `martin/martin.yaml`: registrar a função.
4. `geo.camada`: inserir a linha (cor, minzoom, `tabela` se deve entrar nas sobreposições).

O front e o cruzamento de sobreposições leem o catálogo: não precisa mexer no código deles.

## Escala (quando o volume chegar)

- Servidor do banco: SSD NVMe, RAM ≥ 64 GB, ajustar `PG_SHARED_BUFFERS` / `PG_EFFECTIVE_CACHE_SIZE`.
- Pré-aquecer o cache de tiles até z10–z11 após cada carga (script percorrendo os tiles do Brasil).
- CDN na frente de `/tiles/` (as URLs já são versionadas e cacheáveis).
- Polígonos gigantes (UCs, glebas, terras indígenas): tabela auxiliar com `ST_Subdivide` só para
  render.
- Réplica de leitura do Postgres para o Martin se a geração de tiles concorrer com a API.
