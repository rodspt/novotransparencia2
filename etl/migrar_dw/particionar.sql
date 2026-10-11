-- Migração do schema dw legado: controle + particionamento das tabelas que na origem não são particionadas.
-- Roda DEPOIS do pre-data (tabelas sem índices/constraints) e ANTES de copiar os dados.

CREATE SCHEMA IF NOT EXISTS migracao;

-- Plano: tabelas da origem (não particionadas) que serão criadas particionadas aqui.
--   chave    : coluna de partição (uf_id = código IBGE da UF; ano)
--   add_uf   : a origem não tem uf_id -> cria a coluna (preenchida pelo municipio_id)
CREATE TABLE IF NOT EXISTS migracao.plano_particao (
    tabela  text PRIMARY KEY,
    chave   text NOT NULL,
    add_uf  boolean NOT NULL DEFAULT false
);

INSERT INTO migracao.plano_particao (tabela, chave, add_uf) VALUES
    -- já têm uf_id
    ('dm_censo_ibge_2022', 'uf_id', false), ('dm_sicor_gleba', 'uf_id', false),
    ('dm_sicor_propriedade', 'uf_id', false), ('tb_sicor_dashboard', 'uf_id', false),
    ('dm_sigef', 'uf_id', false), ('tr_sigef_sicor', 'uf_id', false),
    ('dm_sicor_mutuario', 'uf_id', false), ('dm_sicor_complemento_operacao_basica', 'uf_id', false),
    ('dm_sicar', 'uf_id', false), ('tr_sicar_sicor', 'uf_id', false),
    ('tr_floresta_publica_municipio', 'uf_id', false), ('dm_floresta_publica', 'uf_id', false),
    ('dm_minerio', 'uf_id', false), ('dm_auto_infracao', 'uf_id', false),
    ('dm_embargo_estadual', 'uf_id', false), ('tr_assentamento_municipio', 'uf_id', false),
    ('dm_area_urbana', 'uf_id', false), ('dm_assentamento', 'uf_id', false),
    ('tr_terra_indigena_municipio', 'uf_id', false), ('dm_terra_indigena', 'uf_id', false),
    -- só municipio_id: ganham uf_id
    ('dm_qualidade_pastagem', 'uf_id', true), ('dm_uso_solo', 'uf_id', true),
    ('dm_rodovia', 'uf_id', true), ('dm_embargo_ibama', 'uf_id', true),
    ('dm_embargo_icmbio', 'uf_id', true), ('dm_uso_solo_old', 'uf_id', true),
    -- temporais: por ano (e ganham uf_id)
    ('dm_deter', 'ano', true), ('dm_foco_queimada', 'ano', true)
ON CONFLICT (tabela) DO NOTHING;

-- Progresso da cópia, por tabela física (tabela comum ou partição folha).
CREATE TABLE IF NOT EXISTS migracao.copia (
    tabela       text PRIMARY KEY,      -- nome na origem (dw.<tabela>)
    destino      text NOT NULL,         -- tabela local que recebe (o pai, se for particionada aqui)
    blocos       bigint NOT NULL,       -- páginas de 8 kB na origem (só a parte principal)
    bytes_total  bigint,                -- tamanho real na origem, com TOAST (geometrias grandes ficam lá)
    bloco_atual  bigint NOT NULL DEFAULT 0,
    geo          boolean NOT NULL DEFAULT false,
    status       text NOT NULL DEFAULT 'pendente',  -- pendente | copiando | concluida | erro
    bytes        bigint NOT NULL DEFAULT 0,
    tentativas   int NOT NULL DEFAULT 0,
    erro         text,
    atualizado   timestamptz NOT NULL DEFAULT now()
);

-- Transforma dw.<tabela> (vazia, recém-criada pelo pre-data) em particionada.
ALTER TABLE migracao.copia ADD COLUMN IF NOT EXISTS bytes_total bigint;

CREATE OR REPLACE PROCEDURE migracao.particionar(p_tabela text, p_chave text, p_add_uf boolean)
LANGUAGE plpgsql AS $$
DECLARE
    v_orig text := p_tabela || '__orig';
    r      record;
    v_ano  int;
BEGIN
    IF (SELECT relkind FROM pg_class WHERE oid = format('dw.%I', p_tabela)::regclass) = 'p' THEN
        RETURN;  -- já feito
    END IF;
    IF p_add_uf AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = format('dw.%I', p_tabela)::regclass
                                                       AND attname = 'uf_id' AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE dw.%I ADD COLUMN uf_id integer', p_tabela);
    END IF;

    EXECUTE format('ALTER TABLE dw.%I RENAME TO %I', p_tabela, v_orig);
    EXECUTE format('CREATE TABLE dw.%I (LIKE dw.%I INCLUDING DEFAULTS INCLUDING IDENTITY INCLUDING GENERATED INCLUDING CONSTRAINTS
                    INCLUDING STORAGE INCLUDING COMMENTS INCLUDING COMPRESSION) PARTITION BY LIST (%I)',
                   p_tabela, v_orig, p_chave);

    -- sequências (serial) que pertenciam à original passam a pertencer à nova
    FOR r IN SELECT s.oid::regclass AS seq, a.attname
               FROM pg_depend d
               JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
               JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
              WHERE d.refobjid = format('dw.%I', v_orig)::regclass AND d.deptype = 'a'
    LOOP
        EXECUTE format('ALTER SEQUENCE %s OWNED BY dw.%I.%I', r.seq, p_tabela, r.attname);
    END LOOP;

    IF p_chave = 'uf_id' THEN
        FOR r IN SELECT cd_uf, lower(sigla_uf) AS sigla FROM geo.uf LOOP
            EXECUTE format('CREATE TABLE dw.%I PARTITION OF dw.%I FOR VALUES IN (%L)',
                           p_tabela || '_' || r.sigla, p_tabela, r.cd_uf);
        END LOOP;
    ELSE
        FOR v_ano IN 1998 .. extract(year FROM now())::int + 1 LOOP
            EXECUTE format('CREATE TABLE dw.%I PARTITION OF dw.%I FOR VALUES IN (%L)',
                           p_tabela || '_' || v_ano, p_tabela, v_ano);
        END LOOP;
    END IF;
    -- UF/ano vazio ou fora da lista
    EXECUTE format('CREATE TABLE dw.%I PARTITION OF dw.%I DEFAULT', p_tabela || '_default', p_tabela);

    EXECUTE format('DROP TABLE dw.%I', v_orig);
END $$;

-- Colunas para o COPY de uma tabela: lista do destino e expressões do SELECT na origem.
-- Nas tabelas particionadas por UF aqui, uf_id vazio é preenchido pelo código do município
-- (IBGE: 5300108 / 100000 = 53); nas que ganharam uf_id, ele vem só do município.
CREATE OR REPLACE FUNCTION migracao.colunas(p_tabela text, OUT destino text, OUT origem text)
LANGUAGE sql STABLE AS $$
    WITH plano AS (
        SELECT pp.*, EXISTS (SELECT 1 FROM pg_attribute a
                              WHERE a.attrelid = format('dw.%I', p_tabela)::regclass
                                AND a.attname = 'municipio_id' AND NOT a.attisdropped) AS tem_municipio
          FROM migracao.plano_particao pp
         WHERE pp.tabela = p_tabela
    )
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum),
           string_agg(CASE
                          WHEN a.attname = 'uf_id' AND p.add_uf THEN 'municipio_id / 100000 AS uf_id'
                          WHEN a.attname = 'uf_id' AND p.tem_municipio THEN 'coalesce(uf_id, municipio_id / 100000) AS uf_id'
                          ELSE quote_ident(a.attname)
                      END, ', ' ORDER BY a.attnum)
      FROM pg_attribute a
      LEFT JOIN plano p ON true
     WHERE a.attrelid = format('dw.%I', p_tabela)::regclass
       AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';
$$;
