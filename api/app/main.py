"""API de atributos, busca e cruzamentos. Geometria para desenho NÃO passa por aqui: vai por vector tiles (Martin)."""

import json
import os
import re
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException, Query

DATABASE_URL = os.environ["DATABASE_URL"]
EXPOR_DADOS_PESSOAIS = os.getenv("EXPOR_DADOS_PESSOAIS", "false").lower() == "true"
RE_COD_IMOVEL = re.compile(r"^[A-Z]{2}-\d{7}")

pool: asyncpg.Pool


@asynccontextmanager
async def lifespan(_: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=20)
    yield
    await pool.close()


app = FastAPI(title="Novo Transparência", lifespan=lifespan, root_path="/api")


def mascarar(valor: str | None) -> str | None:
    if valor is None or EXPOR_DADOS_PESSOAIS:
        return valor
    digitos = re.sub(r"\D", "", valor)
    if len(digitos) == 11:
        return f"{digitos[:3]}.***.***-{digitos[-2:]}"
    if len(digitos) == 14:
        return f"{digitos[:2]}.***.***/****-{digitos[-2:]}"
    return "***"


# Imóvel do CAR no dw: atributos em dm_sicar, geometria em dm_sicar_geo (ambas particionadas por uf_id).
IMOVEL_SQL = """
    SELECT s.id, s.cod_imovel, st.tx_descricao AS status_imovel, s.dat_criacao, s.area_ha::float8 AS area,
           co.tx_descricao AS condicao, u.sg_uf AS uf, m.nm_municipio AS municipio, s.municipio_id AS cod_municipio_ibge,
           s.modulo_fiscal::float8 AS m_fiscal, ti.tx_descricao AS tipo_imovel, s.nome_imovel,
           s.arr_cpf, s.arr_nome, g.geom
      FROM dw.dm_sicar s
      JOIN dw.dm_uf u ON u.id = s.uf_id
      LEFT JOIN dw.dm_municipio m ON m.id = s.municipio_id
      LEFT JOIN dw.ta_sicar_status st ON st.id = s.sicar_status_id
      LEFT JOIN dw.ta_sicar_condicao co ON co.id = s.sicar_condicao_id
      LEFT JOIN dw.ta_sicar_tipo_imovel ti ON ti.id = s.sicar_tipo_imovel_id
      CROSS JOIN LATERAL (SELECT ST_Collect(geom) AS geom FROM dw.dm_sicar_geo
                           WHERE uf_id = s.uf_id AND sicar_id = s.id) g
"""


async def uf_do_imovel(con: asyncpg.Connection, cod_imovel: str) -> int | None:
    """uf_id (partição) do imóvel. O código começa pela sigla da UF; imóveis de divisa podem estar em outra."""
    uf_id = await con.fetchval(
        "SELECT s.uf_id FROM dw.dm_sicar s JOIN dw.dm_uf u ON u.id = s.uf_id "
        "WHERE u.sg_uf = $1 AND s.cod_imovel = $2 LIMIT 1", cod_imovel[:2].upper(), cod_imovel)
    if uf_id is None:
        uf_id = await con.fetchval("SELECT uf_id FROM dw.dm_sicar WHERE cod_imovel = $1 LIMIT 1", cod_imovel)
    return uf_id


@app.get("/saude")
async def saude():
    return {"ok": await pool.fetchval("SELECT true")}


@app.get("/camadas")
async def camadas():
    rows = await pool.fetch(
        """SELECT id, nome, grupo, fonte, tipo_geom, cor, minzoom, maxzoom, ativo_padrao, versao,
                  tabela IS NOT NULL AS cruzavel
             FROM geo.camada ORDER BY ordem, nome"""
    )
    return [dict(r) for r in rows]


def _resultado_busca(r) -> dict:
    return {**{k: r[k] for k in ("cod_imovel", "nome_imovel", "municipio", "uf", "area")},
            "bbox": [r["xmin"], r["ymin"], r["xmax"], r["ymax"]]}


@app.get("/imoveis/busca")
async def buscar_imoveis(q: str = Query(min_length=3), limite: int = Query(10, le=50)):
    termo = q.strip()
    base = f"""SELECT i.cod_imovel, i.nome_imovel, i.municipio, i.uf, i.area,
                      ST_XMin(i.geom) AS xmin, ST_YMin(i.geom) AS ymin, ST_XMax(i.geom) AS xmax, ST_YMax(i.geom) AS ymax
                 FROM ({IMOVEL_SQL} WHERE {{filtro}} LIMIT $2) i"""
    if RE_COD_IMOVEL.match(termo.upper()):
        filtro = "u.sg_uf = $3 AND s.cod_imovel LIKE $1 || '%'"  # $3 = UF do código: lê só uma partição
        rows = await pool.fetch(base.format(filtro=filtro), termo.upper(), limite, termo[:2].upper())
        if not rows:
            rows = await pool.fetch(base.format(filtro="s.cod_imovel LIKE $1 || '%'"), termo.upper(), limite)
    else:
        rows = await pool.fetch(base.format(filtro="s.nome_imovel ILIKE '%' || $1 || '%'"), termo, limite)
    return [_resultado_busca(r) for r in rows]


@app.get("/imoveis/{cod_imovel}")
async def obter_imovel(cod_imovel: str):
    async with pool.acquire() as con:
        uf_id = await uf_do_imovel(con, cod_imovel)
        if uf_id is None:
            raise HTTPException(404, "Imóvel não encontrado")
        r = await con.fetchrow(
            f"""SELECT i.*, ST_AsGeoJSON(i.geom, 6)::text AS geojson,
                       ST_XMin(i.geom) AS xmin, ST_YMin(i.geom) AS ymin, ST_XMax(i.geom) AS xmax, ST_YMax(i.geom) AS ymax
                  FROM ({IMOVEL_SQL} WHERE s.uf_id = $1 AND s.cod_imovel = $2 LIMIT 1) i""",
            uf_id, cod_imovel,
        )
    imovel = dict(r)
    imovel.pop("geom")
    cpfs = [mascarar(c) for c in (imovel.pop("arr_cpf") or []) if c]
    nomes = imovel.pop("arr_nome") or []
    imovel["cpf_cnpj_proprietario"] = ", ".join(cpfs) or None
    imovel["nome_proprietario"] = (", ".join(n for n in nomes if n) or None) if EXPOR_DADOS_PESSOAIS else None
    imovel["geometria"] = json.loads(imovel.pop("geojson"))
    imovel["bbox"] = [imovel.pop(k) for k in ("xmin", "ymin", "xmax", "ymax")]
    return imovel


@app.get("/imoveis/{cod_imovel}/sobreposicoes")
async def sobreposicoes(cod_imovel: str):
    """Cruza o imóvel com todas as camadas do catálogo marcadas como cruzáveis."""
    async with pool.acquire() as con:
        uf_id = await uf_do_imovel(con, cod_imovel)
        if uf_id is None:
            raise HTTPException(404, "Imóvel não encontrado")
        camadas = await con.fetch(
            "SELECT id, nome, tipo_geom, tabela::text AS tabela FROM geo.camada "
            "WHERE tabela IS NOT NULL AND id <> 'sicar' ORDER BY ordem"
        )
        resultado = []
        for c in camadas:
            # c["tabela"] vem de um regclass do próprio banco (já citado), não de entrada do usuário.
            area = (
                "NULL::float8" if c["tipo_geom"] == "ponto"
                else "sum(ST_Area(ST_Intersection(t.geom, i.geom)::geography)) / 10000"
            )
            try:
                async with con.transaction():
                    # camadas com polígonos enormes (uso do solo, pastagem) não podem travar o painel
                    await con.execute("SET LOCAL statement_timeout = '15s'")
                    r = await con.fetchrow(
                        f"""SELECT count(*) AS qtd, {area} AS area_ha
                              FROM {c["tabela"]} t,
                                   (SELECT ST_Collect(g.geom) AS geom
                                      FROM dw.dm_sicar s JOIN dw.dm_sicar_geo g ON g.uf_id = s.uf_id AND g.sicar_id = s.id
                                     WHERE s.uf_id = $1 AND s.cod_imovel = $2) i
                             WHERE t.geom && i.geom AND ST_Intersects(t.geom, i.geom)""",
                        uf_id, cod_imovel,
                    )
                resultado.append({"camada": c["id"], "nome": c["nome"], "qtd": r["qtd"], "area_ha": r["area_ha"]})
            except asyncpg.QueryCanceledError:
                resultado.append({"camada": c["id"], "nome": c["nome"], "qtd": None, "area_ha": None})
    return resultado
