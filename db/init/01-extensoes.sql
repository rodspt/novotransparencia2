-- Executado apenas na criação do volume do banco (docker-entrypoint-initdb.d).

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- usadas pelo schema dw do banco legado
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- geo     : tabelas curadas (particionadas), fonte da verdade da aplicação
-- staging : cargas brutas (ogr2ogr) antes de normalizar e trocar a partição
-- tiles   : funções que geram vector tiles (MVT) consumidas pelo Martin
CREATE SCHEMA IF NOT EXISTS geo;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS tiles;

-- Tabela de referência de UF. sigla_uf é a chave usada em todas as tabelas geográficas
-- (coluna uf + FK) e é a chave de particionamento das bases cadastrais.
CREATE TABLE geo.uf (
    sigla_uf     char(2)  PRIMARY KEY,
    cd_uf        smallint NOT NULL UNIQUE,   -- código IBGE (2 primeiros dígitos do cód. do município)
    nm_uf        text     NOT NULL,
    cd_regiao    smallint NOT NULL,
    nm_regiao    text     NOT NULL,
    sigla_regiao text     NOT NULL
);

INSERT INTO geo.uf (cd_uf, nm_uf, sigla_uf, cd_regiao, nm_regiao, sigla_regiao) VALUES
    (11, 'Rondônia',            'RO', 1, 'Norte',        'N'),
    (12, 'Acre',                'AC', 1, 'Norte',        'N'),
    (13, 'Amazonas',            'AM', 1, 'Norte',        'N'),
    (14, 'Roraima',             'RR', 1, 'Norte',        'N'),
    (15, 'Pará',                'PA', 1, 'Norte',        'N'),
    (16, 'Amapá',               'AP', 1, 'Norte',        'N'),
    (17, 'Tocantins',           'TO', 1, 'Norte',        'N'),
    (21, 'Maranhão',            'MA', 2, 'Nordeste',     'NE'),
    (22, 'Piauí',               'PI', 2, 'Nordeste',     'NE'),
    (23, 'Ceará',               'CE', 2, 'Nordeste',     'NE'),
    (24, 'Rio Grande do Norte', 'RN', 2, 'Nordeste',     'NE'),
    (25, 'Paraíba',             'PB', 2, 'Nordeste',     'NE'),
    (26, 'Pernambuco',          'PE', 2, 'Nordeste',     'NE'),
    (27, 'Alagoas',             'AL', 2, 'Nordeste',     'NE'),
    (28, 'Sergipe',             'SE', 2, 'Nordeste',     'NE'),
    (29, 'Bahia',               'BA', 2, 'Nordeste',     'NE'),
    (31, 'Minas Gerais',        'MG', 3, 'Sudeste',      'SE'),
    (32, 'Espírito Santo',      'ES', 3, 'Sudeste',      'SE'),
    (33, 'Rio de Janeiro',      'RJ', 3, 'Sudeste',      'SE'),
    (35, 'São Paulo',           'SP', 3, 'Sudeste',      'SE'),
    (41, 'Paraná',              'PR', 4, 'Sul',          'S'),
    (42, 'Santa Catarina',      'SC', 4, 'Sul',          'S'),
    (43, 'Rio Grande do Sul',   'RS', 4, 'Sul',          'S'),
    (50, 'Mato Grosso do Sul',  'MS', 5, 'Centro-oeste', 'CO'),
    (51, 'Mato Grosso',         'MT', 5, 'Centro-oeste', 'CO'),
    (52, 'Goiás',               'GO', 5, 'Centro-oeste', 'CO'),
    (53, 'Distrito Federal',    'DF', 5, 'Centro-oeste', 'CO');

-- Cria uma partição LIST por UF (a partir de geo.uf) para a tabela informada (ex.: geo.sicar -> geo.sicar_df).
CREATE OR REPLACE FUNCTION geo.criar_particoes_uf(p_tabela text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_uf text;
BEGIN
    FOR v_uf IN SELECT sigla_uf FROM geo.uf ORDER BY sigla_uf LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS geo.%I PARTITION OF geo.%I FOR VALUES IN (%L)',
                       p_tabela || '_' || lower(v_uf), p_tabela, v_uf);
    END LOOP;
END $$;

-- Cria partições RANGE anuais (ex.: geo.foco_queimada -> geo.foco_queimada_2024).
CREATE OR REPLACE FUNCTION geo.criar_particoes_ano(p_tabela text, p_ano_ini int, p_ano_fim int)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    FOR v_ano IN p_ano_ini..p_ano_fim LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS geo.%I PARTITION OF geo.%I FOR VALUES FROM (%L) TO (%L)',
                       p_tabela || '_' || v_ano, p_tabela,
                       make_date(v_ano, 1, 1), make_date(v_ano + 1, 1, 1));
    END LOOP;
END $$;

-- Troca a partição de uma UF por uma tabela já carregada, sem derrubar a leitura do mapa.
-- p_nova deve ter a mesma estrutura do pai e um CHECK (uf = '<UF>'): com ele o ATTACH
-- não precisa varrer a tabela, e os índices do pai são criados na nova antes de entrar em uso.
CREATE OR REPLACE PROCEDURE geo.substituir_particao_uf(p_tabela text, p_uf text, p_nova text)
LANGUAGE plpgsql AS $$
DECLARE
    v_part text := p_tabela || '_' || lower(p_uf);
BEGIN
    IF to_regclass(format('geo.%I', v_part)) IS NOT NULL THEN
        EXECUTE format('ALTER TABLE geo.%I DETACH PARTITION geo.%I', p_tabela, v_part);
        EXECUTE format('ALTER TABLE geo.%I RENAME TO %I', v_part, v_part || '_antiga');
    END IF;
    EXECUTE format('ALTER TABLE geo.%I RENAME TO %I', p_nova, v_part);
    EXECUTE format('ALTER TABLE geo.%I ATTACH PARTITION geo.%I FOR VALUES IN (%L)', p_tabela, v_part, p_uf);
    EXECUTE format('DROP TABLE IF EXISTS geo.%I', v_part || '_antiga');
    EXECUTE format('ANALYZE geo.%I', v_part);
END $$;
