-- Bases "cadastrais" (SICAR, SIGEF, glebas, assentamentos...) seguem este molde:
-- particionadas por UF, geometria tipada e SRID fixo (SIRGAS 2000 / 4674).
CREATE TABLE geo.sicar (
    id                    bigint      NOT NULL,
    cod_imovel            text        NOT NULL,
    status_imovel         text,
    dat_criacao           timestamp,
    area                  double precision,
    condicao              text,
    uf                    char(2)     NOT NULL REFERENCES geo.uf,
    municipio             text,
    cod_municipio_ibge    int,
    m_fiscal              double precision,
    tipo_imovel           text,
    nome_imovel           text,
    cpf_cnpj_proprietario text,
    nome_proprietario     text,
    geom                  geometry(MultiPolygon, 4674) NOT NULL,
    dt_inclusao           timestamp   NOT NULL DEFAULT now(),
    PRIMARY KEY (uf, id),
    UNIQUE (uf, cod_imovel)
) PARTITION BY LIST (uf);

SELECT geo.criar_particoes_uf('sicar');

-- Declarados no pai, propagados para cada partição.
CREATE INDEX ON geo.sicar USING gist (geom);
-- text_pattern_ops atende igualdade e busca por prefixo (LIKE 'MT-5103403%').
CREATE INDEX ON geo.sicar (cod_imovel text_pattern_ops);
CREATE INDEX ON geo.sicar (cod_municipio_ibge);
CREATE INDEX ON geo.sicar USING gin (nome_imovel gin_trgm_ops);

-- Normaliza a carga bruta de uma UF (staging.sicar_<uf>, criada pelo ogr2ogr) e troca a partição.
-- Ordenar por geohash agrupa no disco imóveis vizinhos: um tile lê poucas páginas.
CREATE OR REPLACE PROCEDURE geo.carregar_sicar_uf(p_uf text)
LANGUAGE plpgsql AS $$
DECLARE
    v_uf   text := upper(p_uf);
    v_nova text := 'sicar_' || lower(p_uf) || '_nova';
BEGIN
    EXECUTE format('DROP TABLE IF EXISTS geo.%I', v_nova);
    EXECUTE format('CREATE TABLE geo.%I (LIKE geo.sicar INCLUDING DEFAULTS, CHECK (uf = %L))', v_nova, v_uf);
    EXECUTE format($sql$
        INSERT INTO geo.%I (id, cod_imovel, status_imovel, dat_criacao, area, condicao, uf, municipio,
                            cod_municipio_ibge, m_fiscal, tipo_imovel, nome_imovel,
                            cpf_cnpj_proprietario, nome_proprietario, geom, dt_inclusao)
        SELECT * FROM (
            SELECT DISTINCT ON (s.cod_imovel)
                   s.id, s.cod_imovel, s.status_imovel, s.dat_criacao, s.area, s.condicao, upper(s.uf),
                   s.municipio, s.cod_municipio_ibge, s.m_fiscal, s.tipo_imovel, s.nome_imovel,
                   s.cpf_cnpj_proprietario, s.nome_proprietario,
                   g.geom, coalesce(s.dt_inclusao, now())
              FROM staging.%I s
             CROSS JOIN LATERAL (
                   SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Force2D(ST_SetSRID(s.geom, 4674))), 3)) AS geom
             ) g
             WHERE upper(s.uf) = %L AND s.geom IS NOT NULL AND NOT ST_IsEmpty(g.geom)
             ORDER BY s.cod_imovel, s.dt_inclusao DESC NULLS LAST
        ) t
        ORDER BY ST_GeoHash(ST_PointOnSurface(t.geom), 8)
    $sql$, v_nova, 'sicar_' || lower(p_uf), v_uf);

    CALL geo.substituir_particao_uf('sicar', v_uf, v_nova);
    EXECUTE format('DROP TABLE staging.%I', 'sicar_' || lower(p_uf));
    UPDATE geo.camada SET versao = versao + 1, atualizado_em = now() WHERE id = 'sicar';
END $$;
