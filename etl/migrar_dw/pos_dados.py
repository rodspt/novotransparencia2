"""Adapta o post-data do pg_dump (índices, PKs, FKs) às tabelas que foram particionadas no banco novo.

uso: python3 pos_dados.py post.sql plano.txt > post_ajustado.sql 2> ignorados.txt
  plano.txt: linhas "tabela|chave" (migracao.plano_particao)

Regras para tabela particionada aqui (chave = uf_id ou ano):
  * PRIMARY KEY/UNIQUE (cols) sem a chave  -> UNIQUE (cols, chave)   [PostgreSQL exige a chave da partição]
  * FK saindo dela                          -> sem ONLY
  * FK apontando para ela por (id)          -> ignorada: não há mais unicidade só em (id)
  * CLUSTER ON                              -> ignorado (não existe em tabela particionada)
  * CREATE UNIQUE INDEX sem a chave         -> vira índice comum
"""

import re
import sys

post = open(sys.argv[1], encoding="utf-8").read()
plano = dict(l.strip().split("|") for l in open(sys.argv[2], encoding="utf-8") if l.strip())

RE_TABELA = re.compile(r"^ALTER TABLE ONLY dw\.(\w+)\s+(.*)$", re.S)
RE_PK = re.compile(r"ADD CONSTRAINT (\w+) (PRIMARY KEY|UNIQUE) \(([^)]*)\)(.*)$", re.S)
RE_FK = re.compile(r"ADD CONSTRAINT (\w+) FOREIGN KEY \(([^)]*)\) REFERENCES dw\.(\w+)\(([^)]*)\)(.*)$", re.S)
RE_UIDX = re.compile(r"^CREATE UNIQUE INDEX (\w+) ON (?:ONLY )?dw\.(\w+) (.*)$", re.S)


def ignorar(stmt, motivo):
    print(f"-- [{motivo}]\n{stmt};\n", file=sys.stderr)


for bruto in post.split(";\n"):
    linhas = [l for l in bruto.splitlines() if not l.startswith("--")]
    stmt = "\n".join(linhas).strip()
    if not stmt:
        continue

    m = RE_TABELA.match(stmt)
    if m:
        tabela, resto = m.groups()
        fk = RE_FK.match(resto)
        if fk:
            nome, cols, ref, ref_cols, extra = fk.groups()
            if ref in plano and plano[ref] not in [c.strip() for c in ref_cols.split(",")]:
                ignorar(stmt, f"FK para tabela particionada {ref} sem a chave {plano[ref]}")
                continue
            if tabela in plano:
                stmt = f"ALTER TABLE dw.{tabela} {resto}"
        elif tabela in plano:
            pk = RE_PK.match(resto)
            if pk:
                nome, tipo, cols, extra = pk.groups()
                lista = [c.strip() for c in cols.split(",")]
                if plano[tabela] not in lista:
                    lista.append(plano[tabela])
                    tipo = "UNIQUE"  # a chave de partição pode ser nula (partição DEFAULT)
                stmt = f"ALTER TABLE dw.{tabela} ADD CONSTRAINT {nome} {tipo} ({', '.join(lista)}){extra}"
            elif resto.startswith("CLUSTER ON"):
                ignorar(stmt, "CLUSTER não se aplica a tabela particionada")
                continue
            else:
                stmt = f"ALTER TABLE dw.{tabela} {resto}"

    u = RE_UIDX.match(stmt)
    if u and u.group(2) in plano and plano[u.group(2)] not in u.group(3):
        stmt = f"CREATE INDEX {u.group(1)} ON dw.{u.group(2)} {u.group(3)}"
        ignorar(stmt, "índice único sem a chave de partição virou índice comum")

    print(stmt + ";\n")
