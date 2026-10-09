-- Bases temporais (focos de queimada, DETER, PRODES, área queimada) crescem no tempo e são
-- consultadas por período: particionar por data (RANGE) e não por UF. Carga = nova partição.
CREATE TABLE geo.foco_queimada (
    id                 bigint GENERATED ALWAYS AS IDENTITY,
    id_inpe            text,
    data_hora          timestamptz NOT NULL,
    satelite           text,
    uf                 char(2) NOT NULL REFERENCES geo.uf,
    municipio          text,
    cod_municipio_ibge int,
    bioma              text,
    dias_sem_chuva     int,
    precipitacao       real,
    risco_fogo         real,
    frp                real,
    geom               geometry(Point, 4674) NOT NULL,
    PRIMARY KEY (data_hora, id)
) PARTITION BY RANGE (data_hora);

SELECT geo.criar_particoes_ano('foco_queimada', 1998, extract(year FROM now())::int + 1);

CREATE INDEX ON geo.foco_queimada USING gist (geom);
-- BRIN: índice minúsculo, ótimo para dados inseridos em ordem cronológica.
CREATE INDEX ON geo.foco_queimada USING brin (data_hora);
-- Consultas/relatórios por UF dentro de um período ("focos no MT em 2024").
CREATE INDEX ON geo.foco_queimada (uf, data_hora);
