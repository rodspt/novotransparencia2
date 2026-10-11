import type { ExpressionSpecification, Map as MlMap, LayerSpecification } from "maplibre-gl";
import type { Camada } from "./api";

export type Periodo = { ini: string; fim: string };

// Acima deste zoom o MapLibre reaproveita (overzoom) o tile do z14: bem menos requisições.
const MAXZOOM_TILES = 14;

export function urlTiles(c: Camada, periodo: Periodo): string {
  const params = new URLSearchParams({ v: String(c.versao) });
  if (c.id === "foco_queimada") {
    params.set("data_ini", periodo.ini);
    params.set("data_fim", periodo.fim);
  }
  return `${window.location.origin}/tiles/${c.id}/{z}/{x}/{y}?${params}`;
}

export function idsCamadasMapa(c: Camada): string[] {
  return c.tipo_geom === "poligono" ? [`${c.id}-fill`, `${c.id}-line`] : [`${c.id}-${c.tipo_geom}`];
}

function estilos(c: Camada): LayerSpecification[] {
  const base = {
    source: c.id,
    "source-layer": c.id,
    minzoom: c.minzoom,
    maxzoom: c.maxzoom >= 22 ? 24 : c.maxzoom,
    layout: { visibility: c.ativo_padrao ? "visible" : "none" },
  } as const;
  const selecionado: ExpressionSpecification = ["boolean", ["feature-state", "selecionado"], false];

  if (c.id === "municipio_resumo") {
    return [
      {
        ...base,
        id: `${c.id}-fill`,
        type: "fill",
        paint: {
          "fill-color": ["step", ["get", "qtd_car"], "#f1f3f5", 1, "#d3f9d8", 100, "#8ce99a", 1000, "#40c057", 5000, "#2b8a3e"],
          "fill-opacity": 0.7,
        },
      },
      { ...base, id: `${c.id}-line`, type: "line", paint: { "line-color": "#868e96", "line-width": 0.3 } },
    ];
  }

  switch (c.tipo_geom) {
    case "poligono":
      return [
        {
          ...base,
          id: `${c.id}-fill`,
          type: "fill",
          paint: { "fill-color": c.cor, "fill-opacity": ["case", selecionado, 0.55, 0.2] },
        },
        {
          ...base,
          id: `${c.id}-line`,
          type: "line",
          paint: { "line-color": c.cor, "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.4, 14, 1.5] },
        },
      ];
    case "linha":
      return [{ ...base, id: `${c.id}-linha`, type: "line", paint: { "line-color": c.cor, "line-width": 1.5 } }];
    case "ponto":
      return [
        {
          ...base,
          id: `${c.id}-ponto`,
          type: "circle",
          paint: {
            // "qtd" > 1 quando o tile vem agregado (zoom baixo)
            "circle-radius": ["interpolate", ["linear"], ["coalesce", ["get", "qtd"], 1], 1, 3, 10, 6, 100, 10, 1000, 16],
            "circle-color": c.cor,
            "circle-opacity": 0.75,
            "circle-stroke-color": "#fff",
            "circle-stroke-width": 0.5,
          },
        },
      ];
  }
}

export function adicionarCamadas(map: MlMap, camadas: Camada[], periodo: Periodo) {
  // pontos por cima de polígonos, respeitando a ordem do catálogo
  const ordenadas = [...camadas].sort((a, b) => Number(a.tipo_geom === "ponto") - Number(b.tipo_geom === "ponto"));
  for (const c of ordenadas) {
    if (map.getSource(c.id)) continue;
    map.addSource(c.id, {
      type: "vector",
      tiles: [urlTiles(c, periodo)],
      minzoom: c.minzoom,
      maxzoom: Math.min(c.maxzoom, MAXZOOM_TILES),
    });
    for (const layer of estilos(c)) map.addLayer(layer);
  }
}

// ---- Destaque da feição clicada -------------------------------------------------------------
// Cada camada tem um par "halo + destaque" desenhado da própria fonte de tiles, filtrado pelo id
// da feição clicada. Assim o contorno sai inteiro, sem costuras nas bordas dos tiles.

// O destaque usa a cor da própria camada; esta é só a cor de reserva.
export const COR_DESTAQUE = "#f03e3e";
export const FILTRO_NENHUM: ExpressionSpecification = ["!", true];  // filtro que não aceita nenhuma feição

export type IdsDestaque = { preenchimento?: string; halo: string; linha: string };

export function idsDestaque(c: Camada): IdsDestaque {
  return {
    // polígono maior que a tela: a borda some, então o interior também pulsa
    preenchimento: c.tipo_geom === "poligono" ? `${c.id}-destaque-fill` : undefined,
    halo: `${c.id}-destaque-halo`,
    linha: `${c.id}-destaque`,
  };
}

/** Opacidade máxima do preenchimento pulsante (a linha vai até 1). */
export const OPACIDADE_PREENCHIMENTO = 0.3;

export function adicionarDestaques(map: MlMap, camadas: Camada[]) {
  for (const c of camadas) {
    const { preenchimento, halo, linha } = idsDestaque(c);
    if (map.getLayer(linha)) continue;
    const base = {
      source: c.id,
      "source-layer": c.id,
      minzoom: c.minzoom,
      maxzoom: c.maxzoom >= 22 ? 24 : c.maxzoom,
      filter: FILTRO_NENHUM,
      layout: { visibility: c.ativo_padrao ? "visible" : "none" },
    } as const;
    if (c.tipo_geom === "ponto") {
      map.addLayer({ ...base, id: halo, type: "circle",
        paint: { "circle-radius": 11, "circle-color": "rgba(0,0,0,0)", "circle-stroke-color": "#fff", "circle-stroke-width": 6 } });
      map.addLayer({ ...base, id: linha, type: "circle",
        paint: { "circle-radius": 11, "circle-color": "rgba(0,0,0,0)", "circle-stroke-color": c.cor, "circle-stroke-width": 3 } });
    } else {
      if (preenchimento)
        map.addLayer({ ...base, id: preenchimento, type: "fill",
          paint: { "fill-color": c.cor, "fill-opacity": OPACIDADE_PREENCHIMENTO } });
      map.addLayer({ ...base, id: halo, type: "line", layout: { ...base.layout, "line-join": "round" },
        paint: { "line-color": "#fff", "line-width": 7, "line-opacity": 0.9 } });
      map.addLayer({ ...base, id: linha, type: "line", layout: { ...base.layout, "line-join": "round" },
        paint: { "line-color": c.cor, "line-width": 3.5 } });
    }
  }
}

/** Propriedade de opacidade que pisca, conforme o tipo da camada de destaque. */
export function propOpacidade(map: MlMap, layerId: string): "line-opacity" | "circle-stroke-opacity" | "fill-opacity" {
  const tipo = map.getLayer(layerId)?.type;
  return tipo === "circle" ? "circle-stroke-opacity" : tipo === "fill" ? "fill-opacity" : "line-opacity";
}
