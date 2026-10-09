-- SIGEF (INCRA): parcelas georreferenciadas. Mesmo molde do SICAR: particionado por UF.
-- Origem: dw.dm_sigef do banco legado (sem a coluna geojson, que duplicava a geometria).

CREATE TABLE geo.sigef_status (
    id           int PRIMARY KEY,
    tx_descricao text NOT NULL
);

CREATE TABLE geo.sigef_natureza (
    id           int PRIMARY KEY,
    tx_descricao text NOT NULL
);

CREATE TABLE geo.sigef (
    id                    bigint  NOT NULL,
    qrcode                varchar(36),
    nm_area               text,
    sncr                  varchar(13),
    rt                    text,
    art                   text,
    registro_matricula    text,
    dt_registro_matricula date,
    dt_submissao          date,
    dt_aprovacao          date,
    area_ha               numeric(20, 4),
    sigef_status_id       int REFERENCES geo.sigef_status,
    sigef_natureza_id     int REFERENCES geo.sigef_natureza,
    modulo_fiscal         numeric,
    modulo_fiscal_id      int,
    uf                    char(2) NOT NULL REFERENCES geo.uf,
    cod_municipio_ibge    int,
    geom                  geometry(MultiPolygon, 4674) NOT NULL,
    dt_inclusao           timestamp NOT NULL DEFAULT now(),
    PRIMARY KEY (uf, id)
) PARTITION BY LIST (uf);

SELECT geo.criar_particoes_uf('sigef');

CREATE INDEX ON geo.sigef USING gist (geom);
CREATE INDEX ON geo.sigef (qrcode);
CREATE INDEX ON geo.sigef (sncr);
CREATE INDEX ON geo.sigef (cod_municipio_ibge);

-- Normaliza staging.sigef_<uf> e troca a partição (mesma lógica de geo.carregar_sicar_uf).
CREATE OR REPLACE PROCEDURE geo.carregar_sigef_uf(p_uf text)
LANGUAGE plpgsql AS $$
DECLARE
    v_uf   text := upper(p_uf);
    v_nova text := 'sigef_' || lower(p_uf) || '_nova';
BEGIN
    EXECUTE format('DROP TABLE IF EXISTS geo.%I', v_nova);
    EXECUTE format('CREATE TABLE geo.%I (LIKE geo.sigef INCLUDING DEFAULTS, CHECK (uf = %L))', v_nova, v_uf);
    EXECUTE format($sql$
        INSERT INTO geo.%I (id, qrcode, nm_area, sncr, rt, art, registro_matricula, dt_registro_matricula,
                            dt_submissao, dt_aprovacao, area_ha, sigef_status_id, sigef_natureza_id,
                            modulo_fiscal, modulo_fiscal_id, uf, cod_municipio_ibge, geom, dt_inclusao)
        SELECT s.id, s.qrcode, s.nm_area, s.sncr, s.rt, s.art, s.registro_matricula, s.dt_registro_matricula,
               s.dt_submissao, s.dt_aprovacao, s.area_ha, s.sigef_status_id, s.sigef_natureza_id,
               s.modulo_fiscal, s.modulo_fiscal_id, %L, s.municipio_id, g.geom, coalesce(s.dt_inclusao, now())
          FROM staging.%I s
         CROSS JOIN LATERAL (
               SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Force2D(ST_SetSRID(s.geom, 4674))), 3)) AS geom
         ) g
         WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(g.geom)
         ORDER BY ST_GeoHash(ST_PointOnSurface(g.geom), 8)
    $sql$, v_nova, v_uf, 'sigef_' || lower(p_uf));

    CALL geo.substituir_particao_uf('sigef', v_uf, v_nova);
    EXECUTE format('DROP TABLE staging.%I', 'sigef_' || lower(p_uf));
    UPDATE geo.camada SET versao = versao + 1, atualizado_em = now() WHERE id = 'sigef';
END $$;
