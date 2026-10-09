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


def uf_do_codigo(cod_imovel: str) -> str:
    # O código do CAR começa pela UF: filtrar por ela faz o Postgres ler só uma partição.
    return cod_imovel[:2].upper()


async def uf_do_imovel(con: asyncpg.Connection, cod_imovel: str) -> str | None:
    """UF (partição) do imóvel. Imóveis de divisa têm a UF do código diferente da UF de localização."""
    uf = uf_do_codigo(cod_imovel)
    if await con.fetchval("SELECT true FROM geo.sicar WHERE uf = $1 AND cod_imovel = $2", uf, cod_imovel):
        return uf
    return await con.fetchval("SELECT uf FROM geo.sicar WHERE cod_imovel = $1 LIMIT 1", cod_imovel)


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


@app.get("/imoveis/busca")
async def buscar_imoveis(q: str = Query(min_length=3), limite: int = Query(10, le=50)):
    termo = q.strip()
    if RE_COD_IMOVEL.match(termo.upper()):
        sql = """SELECT cod_imovel, nome_imovel, municipio, uf, area,
                        ST_XMin(geom) AS xmin, ST_YMin(geom) AS ymin, ST_XMax(geom) AS xmax, ST_YMax(geom) AS ymax
                   FROM geo.sicar
                  WHERE {filtro} cod_imovel LIKE $1 || '%'
                  ORDER BY cod_imovel LIMIT $2"""
        rows = await pool.fetch(sql.format(filtro="uf = $3 AND"), termo.upper(), limite, uf_do_codigo(termo))
        if not rows:
            rows = await pool.fetch(sql.format(filtro=""), termo.upper(), limite)
    else:
        rows = await pool.fetch(
            """SELECT cod_imovel, nome_imovel, municipio, uf, area,
                      ST_XMin(geom) AS xmin, ST_YMin(geom) AS ymin, ST_XMax(geom) AS xmax, ST_YMax(geom) AS ymax
                 FROM geo.sicar
                WHERE nome_imovel ILIKE '%' || $1 || '%'
                ORDER BY similarity(nome_imovel, $1) DESC LIMIT $2""",
            termo, limite,
        )
    return [
        {**{k: r[k] for k in ("cod_imovel", "nome_imovel", "municipio", "uf", "area")},
         "bbox": [r["xmin"], r["ymin"], r["xmax"], r["ymax"]]}
        for r in rows
    ]


@app.get("/imoveis/{cod_imovel}")
async def obter_imovel(cod_imovel: str):
    async with pool.acquire() as con:
        uf = await uf_do_imovel(con, cod_imovel)
        if uf is None:
            raise HTTPException(404, "Imóvel não encontrado")
        r = await con.fetchrow(
            """SELECT id, cod_imovel, status_imovel, dat_criacao, area, condicao, uf, municipio,
                      cod_municipio_ibge, m_fiscal, tipo_imovel, nome_imovel,
                      cpf_cnpj_proprietario, nome_proprietario, dt_inclusao,
                      ST_AsGeoJSON(geom, 6)::text AS geojson,
                      ST_XMin(geom) AS xmin, ST_YMin(geom) AS ymin, ST_XMax(geom) AS xmax, ST_YMax(geom) AS ymax
                 FROM geo.sicar WHERE uf = $1 AND cod_imovel = $2""",
            uf, cod_imovel,
        )
    imovel = dict(r)
    imovel["cpf_cnpj_proprietario"] = mascarar(imovel["cpf_cnpj_proprietario"])
    if not EXPOR_DADOS_PESSOAIS:
        imovel["nome_proprietario"] = None
    imovel["geometria"] = json.loads(imovel.pop("geojson"))
    imovel["bbox"] = [imovel.pop(k) for k in ("xmin", "ymin", "xmax", "ymax")]
    return imovel


@app.get("/imoveis/{cod_imovel}/sobreposicoes")
async def sobreposicoes(cod_imovel: str):
    """Cruza o imóvel com todas as camadas do catálogo marcadas como cruzáveis."""
    async with pool.acquire() as con:
        uf = await uf_do_imovel(con, cod_imovel)
        if uf is None:
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
            r = await con.fetchrow(
                f"""SELECT count(*) AS qtd, {area} AS area_ha
                      FROM {c["tabela"]} t,
                           (SELECT geom FROM geo.sicar WHERE uf = $1 AND cod_imovel = $2) i
                     WHERE t.geom && i.geom AND ST_Intersects(t.geom, i.geom)""",
                uf, cod_imovel,
            )
            resultado.append({"camada": c["id"], "nome": c["nome"], "qtd": r["qtd"], "area_ha": r["area_ha"]})
    return resultado
