-- Imóveis FICTÍCIOS para desenvolvimento/demonstração. Não carregar em produção.
-- Lotes vizinhos gerados por Voronoi dentro de municípios reais (geo.municipio precisa estar carregada).
-- Identificáveis por id >= 900000000; remover com CALL geo.remover_imoveis_exemplo();

-- CPF com formato real mas dígito verificador propositalmente INVÁLIDO: nunca coincide com um CPF de verdade.
CREATE OR REPLACE FUNCTION geo.cpf_ficticio()
RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    d  int[] := ARRAY(SELECT floor(random() * 10)::int FROM generate_series(1, 9));
    s  int := 0;
    v1 int;
    v2 int;
BEGIN
    FOR i IN 1..9 LOOP s := s + d[i] * (11 - i); END LOOP;
    v1 := CASE WHEN s % 11 < 2 THEN 0 ELSE 11 - s % 11 END;
    s := v1 * 2;
    FOR i IN 1..9 LOOP s := s + d[i] * (12 - i); END LOOP;
    v2 := CASE WHEN s % 11 < 2 THEN 0 ELSE 11 - s % 11 END;
    v2 := (v2 + 1) % 10;  -- quebra o DV
    RETURN format('%s%s%s.%s%s%s.%s%s%s-%s%s', d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], v1, v2);
END $$;

CREATE OR REPLACE FUNCTION geo.sortear(p_opcoes text[])
RETURNS text LANGUAGE sql VOLATILE AS $$
    SELECT p_opcoes[1 + floor(random() * array_length(p_opcoes, 1))::int];
$$;

CREATE OR REPLACE PROCEDURE geo.gerar_imoveis_exemplo(p_uf text, p_municipios int DEFAULT 8, p_por_municipio int DEFAULT 60)
LANGUAGE plpgsql AS $$
DECLARE
    v_uf       char(2) := upper(p_uf);
    v_regiao   text;
    v_media_ha float8;   -- tamanho médio do imóvel (ha)
    v_modulo   float8;   -- módulo fiscal aproximado (ha)
    v_id       bigint;
    v_lado     float8;
    v_area     geometry;
    m          record;
BEGIN
    SELECT sigla_regiao INTO v_regiao FROM geo.uf WHERE sigla_uf = v_uf;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'UF % inexistente', v_uf;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM geo.municipio WHERE uf = v_uf) THEN
        RAISE EXCEPTION 'Sem municípios para %: rode etl/importar_municipios.sh', v_uf;
    END IF;

    v_media_ha := CASE v_regiao WHEN 'N' THEN 350 WHEN 'CO' THEN 450 WHEN 'NE' THEN 90 WHEN 'SE' THEN 60 ELSE 45 END;
    v_modulo   := CASE v_regiao WHEN 'N' THEN 80  WHEN 'CO' THEN 60  WHEN 'NE' THEN 50 WHEN 'SE' THEN 30 ELSE 20 END;
    -- lado do quadrado (m) onde os imóveis do município são distribuídos; 1.3 compensa os vazios
    v_lado := sqrt(p_por_municipio * v_media_ha * 10000 * 1.3);

    FOR m IN SELECT cod_ibge, nome, ST_Transform(geom, 5880) AS geom   -- 5880: SIRGAS 2000 / Brazil Polyconic (metros)
               FROM geo.municipio WHERE uf = v_uf ORDER BY random() LIMIT p_municipios
    LOOP
        SELECT greatest(coalesce(max(id), 0), 899999999) INTO v_id FROM geo.sicar;
        v_area := ST_Intersection(m.geom, ST_Expand(ST_GeometryN(ST_GeneratePoints(m.geom, 1), 1), v_lado / 2));

        INSERT INTO geo.sicar (id, cod_imovel, status_imovel, dat_criacao, area, condicao, uf, municipio,
                               cod_municipio_ibge, m_fiscal, tipo_imovel, nome_imovel,
                               cpf_cnpj_proprietario, nome_proprietario, geom)
        SELECT v_id + row_number() OVER (ORDER BY ST_GeoHash(ST_PointOnSurface(l.geom))),
               v_uf || '-' || m.cod_ibge || '-' || upper(md5(random()::text)),
               a.status,
               timestamp '2014-05-05' + random() * (now() - timestamp '2014-05-05'),
               round(l.area_ha::numeric, 4),
               CASE a.status
                   WHEN 'CA' THEN 'Cancelado por decisão administrativa'
                   WHEN 'SU' THEN 'Analisado, com pendências, aguardando retificação'
                   ELSE geo.sortear(ARRAY['Aguardando análise', 'Aguardando análise', 'Em análise',
                                          'Analisado, em conformidade com a Lei nº 12.651/2012',
                                          'Analisado, aguardando regularização ambiental (Lei nº 12.651/2012)'])
               END,
               v_uf, m.nome, m.cod_ibge,
               round((l.area_ha / v_modulo)::numeric, 4),
               a.tipo,
               CASE a.tipo
                   WHEN 'AST' THEN 'Assentamento ' || geo.sortear(ARRAY['Nova Conquista', 'Terra Livre', 'Chico Mendes', 'Boa Esperança', 'Santa Luzia'])
                   WHEN 'PCT' THEN 'Território Tradicional ' || geo.sortear(ARRAY['Vereda Grande', 'Fundo de Pasto', 'Ribeirinho do Moura', 'Brejo Alto'])
                   ELSE geo.sortear(ARRAY['Fazenda', 'Fazenda', 'Fazenda', 'Sítio', 'Sítio', 'Chácara', 'Estância', 'Recanto'])
                        || ' ' ||
                        geo.sortear(ARRAY['Boa Vista', 'Santa Rita', 'São José', 'Bela Vista', 'Água Limpa', 'Primavera',
                                          'Esperança', 'Santo Antônio', 'Três Irmãos', 'Rio Claro', 'Capão Alto', 'Serra Azul',
                                          'Palmeiras', 'Buriti', 'Ipê Amarelo', 'Vale Verde', 'Lagoa Seca', 'Barreiro',
                                          'Bom Jardim', 'Nossa Senhora Aparecida', 'Cachoeira', 'Pontal', 'Aroeira', 'Jatobá'])
                        || CASE WHEN random() < 0.15 THEN ' ' || geo.sortear(ARRAY['I', 'II', 'III']) ELSE '' END
               END,
               geo.cpf_ficticio(),
               geo.sortear(ARRAY['João', 'Maria', 'José', 'Ana', 'Antônio', 'Francisca', 'Carlos', 'Luiza', 'Paulo',
                                 'Adriana', 'Pedro', 'Juliana', 'Lucas', 'Márcia', 'Marcos', 'Fernanda', 'Rafael', 'Sandra'])
               || ' ' || geo.sortear(ARRAY['da Silva', 'dos Santos', 'Oliveira', 'Souza', 'Rodrigues', 'Ferreira', 'Alves',
                                           'Pereira', 'Lima', 'Gomes', 'Costa', 'Ribeiro', 'Martins', 'Carvalho', 'Almeida'])
               || ' (FICTÍCIO)',
               l.geom
          FROM (
                SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(g.geom, 4674)), 3)) AS geom,
                       ST_Area(g.geom) / 10000 AS area_ha
                  FROM (
                        -- cada célula vira um lote; buffer negativo separa vizinhos; ~15% das células ficam vazias
                        SELECT ST_Buffer(ST_Intersection(c.geom, v_area), -15, 'join=mitre') AS geom
                          FROM ST_Dump(ST_VoronoiPolygons(ST_GeneratePoints(v_area, p_por_municipio), 0, v_area)) c
                         WHERE random() > 0.15
                       ) g
                 WHERE NOT ST_IsEmpty(g.geom) AND ST_Area(g.geom) > 10000
               ) l
         CROSS JOIN LATERAL (
                SELECT CASE WHEN r < 0.70 THEN 'AT' WHEN r < 0.90 THEN 'PE' WHEN r < 0.97 THEN 'SU' ELSE 'CA' END AS status,
                       CASE WHEN t < 0.93 THEN 'IRU' WHEN t < 0.98 THEN 'AST' ELSE 'PCT' END AS tipo
                  FROM (SELECT random() AS r, random() AS t, l.geom) x   -- l.geom força sorteio por linha
               ) a;
    END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE geo.remover_imoveis_exemplo()
LANGUAGE sql AS $$
    DELETE FROM geo.sicar WHERE id >= 900000000;
$$;
