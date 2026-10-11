export type Camada = {
  id: string;
  nome: string;
  grupo: string;
  fonte: string | null;
  tipo_geom: "poligono" | "linha" | "ponto";
  cor: string;
  minzoom: number;
  maxzoom: number;
  ativo_padrao: boolean;
  versao: number;
  cruzavel: boolean;
};

export type Bbox = [number, number, number, number];

export type ResultadoBusca = {
  cod_imovel: string;
  nome_imovel: string | null;
  municipio: string | null;
  uf: string;
  area: number | null;
  bbox: Bbox;
};

export type Imovel = {
  id: number;
  cod_imovel: string;
  status_imovel: string | null;
  dat_criacao: string | null;
  area: number | null;
  condicao: string | null;
  uf: string;
  municipio: string | null;
  cod_municipio_ibge: number | null;
  m_fiscal: number | null;
  tipo_imovel: string | null;
  nome_imovel: string | null;
  cpf_cnpj_proprietario: string | null;
  nome_proprietario: string | null;
  geometria: GeoJSON.Geometry;
  bbox: Bbox;
};

// qtd/area_ha nulos = cálculo excedeu o tempo limite na API
export type Sobreposicao = { camada: string; nome: string; qtd: number | null; area_ha: number | null };

async function get<T>(caminho: string): Promise<T> {
  const r = await fetch(`/api${caminho}`);
  if (!r.ok) throw new Error(`${r.status} em ${caminho}`);
  return r.json();
}

export const api = {
  camadas: () => get<Camada[]>("/camadas"),
  buscar: (q: string) => get<ResultadoBusca[]>(`/imoveis/busca?q=${encodeURIComponent(q)}`),
  imovel: (cod: string) => get<Imovel>(`/imoveis/${encodeURIComponent(cod)}`),
  sobreposicoes: (cod: string) => get<Sobreposicao[]>(`/imoveis/${encodeURIComponent(cod)}/sobreposicoes`),
};
