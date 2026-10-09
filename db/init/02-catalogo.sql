-- Catálogo de camadas: o frontend monta o mapa a partir daqui e a API usa
-- para cruzar um imóvel com as demais bases. Nova camada = nova linha + função em tiles.*.
CREATE TABLE geo.camada (
    id            text PRIMARY KEY,               -- nome da source no Martin (/tiles/<id>/{z}/{x}/{y})
    nome          text NOT NULL,
    grupo         text NOT NULL,                  -- Fundiário, Ambiental, Fogo, Agro ...
    fonte         text,
    tipo_geom     text NOT NULL CHECK (tipo_geom IN ('poligono', 'linha', 'ponto')),
    cor           text NOT NULL,
    minzoom       int  NOT NULL DEFAULT 0,
    maxzoom       int  NOT NULL DEFAULT 22,
    tabela        regclass,                       -- NULL = não entra no cruzamento de sobreposições
    ativo_padrao  boolean NOT NULL DEFAULT false,
    ordem         int  NOT NULL DEFAULT 0,
    versao        int  NOT NULL DEFAULT 1,        -- incrementar a cada carga: invalida o cache de tiles
    atualizado_em timestamptz NOT NULL DEFAULT now()
);
