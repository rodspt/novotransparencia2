"use client";

import maplibregl, { type Map as MlMap, type MapGeoJSONFeature } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import { api, type Bbox, type Camada, type Imovel, type ResultadoBusca, type Sobreposicao } from "@/lib/api";
import { adicionarCamadas, idsCamadasMapa, urlTiles, type Periodo } from "@/lib/camadas-mapa";

const ESTILO_BASE = "https://tiles.openfreemap.org/styles/positron";
const fmt = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 2 });

function periodoPadrao(): Periodo {
  const hoje = new Date();
  const ini = new Date(hoje.getTime() - 30 * 86400_000);
  return { ini: ini.toISOString().slice(0, 10), fim: hoje.toISOString().slice(0, 10) };
}

export default function Explorador() {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MlMap | null>(null);
  const selecionadoRef = useRef<MapGeoJSONFeature | null>(null);
  const [mapaPronto, setMapaPronto] = useState(false);
  const [camadas, setCamadas] = useState<Camada[]>([]);
  const [visiveis, setVisiveis] = useState<Set<string>>(new Set());
  const [periodo, setPeriodo] = useState<Periodo>(periodoPadrao);
  const [zoom, setZoom] = useState(3.6);
  const [busca, setBusca] = useState("");
  const [resultados, setResultados] = useState<ResultadoBusca[]>([]);
  const [imovel, setImovel] = useState<Imovel | null>(null);
  const [sobreposicoes, setSobreposicoes] = useState<Sobreposicao[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);

  // mapa
  useEffect(() => {
    const map = new maplibregl.Map({
      container: container.current!,
      style: ESTILO_BASE,
      center: [-52, -14],
      zoom: 3.6,
      minZoom: 3,
      maxBounds: [[-82, -38], [-26, 10]],
      attributionControl: { compact: true },
    });
    map.addControl(new maplibregl.NavigationControl(), "top-right");
    map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-right");
    map.on("load", () => {
      // Máscara: cobre os outros países (mapa base inteiro, inclusive rótulos); nossas camadas ficam por cima.
      map.addSource("brasil_mascara", {
        type: "vector",
        tiles: [`${window.location.origin}/tiles/brasil_mascara/{z}/{x}/{y}?v=1`],
        maxzoom: 14,
      });
      map.addLayer({
        id: "brasil-mascara",
        type: "fill",
        source: "brasil_mascara",
        "source-layer": "brasil_mascara",
        filter: ["==", ["get", "tipo"], "mascara"],
        paint: { "fill-color": "rgb(242,243,240)", "fill-antialias": false },
      });
      map.addLayer({
        id: "brasil-contorno",
        type: "line",
        source: "brasil_mascara",
        "source-layer": "brasil_mascara",
        filter: ["==", ["get", "tipo"], "contorno"],
        paint: { "line-color": "#868e96", "line-width": ["interpolate", ["linear"], ["zoom"], 3, 0.8, 10, 2] },
      });
      map.addSource("destaque", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      map.addLayer({ id: "destaque", type: "line", source: "destaque", paint: { "line-color": "#f03e3e", "line-width": 3 } });
      setMapaPronto(true);
    });
    map.on("zoomend", () => setZoom(map.getZoom()));
    mapRef.current = map;
    return () => map.remove();
  }, []);

  // catálogo
  useEffect(() => {
    api.camadas()
      .then((cs) => {
        setCamadas(cs);
        setVisiveis(new Set(cs.filter((c) => c.ativo_padrao).map((c) => c.id)));
      })
      .catch((e) => setErro(`Falha ao carregar camadas: ${e.message}`));
  }, []);

  // camadas no mapa + clique
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !mapaPronto || camadas.length === 0) return;
    adicionarCamadas(map, camadas, periodo);
    map.moveLayer("destaque");

    const clicaveis = camadas.flatMap((c) => idsCamadasMapa(c)).filter((id) => !id.endsWith("-line"));
    const aoClicar = (e: maplibregl.MapMouseEvent) => {
      const [f] = map.queryRenderedFeatures(e.point, { layers: clicaveis.filter((id) => map.getLayer(id)) });
      if (!f) return;
      if (f.source === "sicar") {
        marcarSelecionado(f);
        void abrirImovel(String(f.properties.cod_imovel));
      } else {
        new maplibregl.Popup({ maxWidth: "320px" })
          .setLngLat(e.lngLat)
          .setHTML(htmlPopup(f))
          .addTo(map);
      }
    };
    const cursor = (v: string) => () => (map.getCanvas().style.cursor = v);
    map.on("click", aoClicar);
    for (const id of clicaveis) {
      map.on("mouseenter", id, cursor("pointer"));
      map.on("mouseleave", id, cursor(""));
    }
    return () => {
      map.off("click", aoClicar);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapaPronto, camadas]);

  // visibilidade
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !mapaPronto) return;
    for (const c of camadas)
      for (const id of idsCamadasMapa(c))
        if (map.getLayer(id)) map.setLayoutProperty(id, "visibility", visiveis.has(c.id) ? "visible" : "none");
  }, [visiveis, camadas, mapaPronto]);

  // período dos focos => nova URL de tiles (e nova chave de cache)
  useEffect(() => {
    const map = mapRef.current;
    const focos = camadas.find((c) => c.id === "foco_queimada");
    const src = map?.getSource("foco_queimada") as maplibregl.VectorTileSource | undefined;
    if (focos && src) src.setTiles([urlTiles(focos, periodo)]);
  }, [periodo, camadas]);

  // busca com debounce
  useEffect(() => {
    if (busca.trim().length < 3) return setResultados([]);
    const t = setTimeout(() => api.buscar(busca).then(setResultados).catch(() => setResultados([])), 300);
    return () => clearTimeout(t);
  }, [busca]);

  function marcarSelecionado(f: MapGeoJSONFeature | null) {
    const map = mapRef.current!;
    const anterior = selecionadoRef.current;
    if (anterior?.id !== undefined) map.setFeatureState(anterior, { selecionado: false });
    if (f?.id !== undefined) map.setFeatureState(f, { selecionado: true });
    selecionadoRef.current = f;
  }

  async function abrirImovel(cod: string, enquadrar = false) {
    setErro(null);
    setSobreposicoes(null);
    try {
      const im = await api.imovel(cod);
      setImovel(im);
      const map = mapRef.current!;
      (map.getSource("destaque") as maplibregl.GeoJSONSource).setData({ type: "Feature", geometry: im.geometria, properties: {} });
      if (enquadrar) enquadrarBbox(im.bbox);
      setSobreposicoes(await api.sobreposicoes(cod));
    } catch (e) {
      setErro((e as Error).message);
    }
  }

  function enquadrarBbox(b: Bbox) {
    mapRef.current?.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: 80, maxZoom: 15, duration: 800 });
  }

  function fecharImovel() {
    setImovel(null);
    setSobreposicoes(null);
    marcarSelecionado(null);
    (mapRef.current?.getSource("destaque") as maplibregl.GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: [] });
  }

  const grupos = useMemo(() => {
    const g = new Map<string, Camada[]>();
    for (const c of camadas) g.set(c.grupo, [...(g.get(c.grupo) ?? []), c]);
    return [...g.entries()];
  }, [camadas]);

  function alternar(id: string) {
    setVisiveis((v) => {
      const n = new Set(v);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  }

  return (
    <div className="explorador">
      <aside className="painel">
        <header>
          <h1>Novo Transparência</h1>
          <p className="sub">Bases fundiárias e ambientais do Brasil</p>
        </header>

        <section>
          <input
            className="busca"
            placeholder="Código do CAR ou nome do imóvel"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
          />
          {resultados.length > 0 && (
            <ul className="resultados">
              {resultados.map((r) => (
                <li key={r.cod_imovel}>
                  <button
                    onClick={() => {
                      setBusca("");
                      setResultados([]);
                      void abrirImovel(r.cod_imovel, true);
                    }}
                  >
                    <strong>{r.nome_imovel ?? r.cod_imovel}</strong>
                    <span>{r.municipio}/{r.uf} · {fmt.format(r.area ?? 0)} ha</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>

        {erro && <p className="erro">{erro}</p>}

        {imovel ? (
          <section className="imovel">
            <div className="titulo-secao">
              <h2>{imovel.nome_imovel ?? "Imóvel"}</h2>
              <button className="fechar" onClick={fecharImovel} aria-label="Fechar">×</button>
            </div>
            <dl>
              <dt>Código</dt><dd className="mono">{imovel.cod_imovel}</dd>
              <dt>Situação</dt><dd>{imovel.status_imovel}</dd>
              <dt>Tipo</dt><dd>{imovel.tipo_imovel}</dd>
              <dt>Área</dt><dd>{fmt.format(imovel.area ?? 0)} ha ({fmt.format(imovel.m_fiscal ?? 0)} mód. fiscais)</dd>
              <dt>Município</dt><dd>{imovel.municipio}/{imovel.uf}</dd>
              <dt>Condição</dt><dd>{imovel.condicao}</dd>
              <dt>Proprietário</dt><dd>{imovel.nome_proprietario ?? "—"} {imovel.cpf_cnpj_proprietario && <span className="mono">({imovel.cpf_cnpj_proprietario})</span>}</dd>
            </dl>
            <h3>Sobreposições</h3>
            {sobreposicoes === null ? (
              <p className="sub">Calculando…</p>
            ) : sobreposicoes.length === 0 ? (
              <p className="sub">Nenhuma camada cruzável carregada.</p>
            ) : (
              <ul className="sobreposicoes">
                {sobreposicoes.map((s) => (
                  <li key={s.camada} className={s.qtd > 0 ? "alerta" : ""}>
                    <span>{s.nome}</span>
                    <span>{s.qtd}{s.area_ha != null && s.qtd > 0 ? ` · ${fmt.format(s.area_ha)} ha` : ""}</span>
                  </li>
                ))}
              </ul>
            )}
            <button className="link" onClick={() => enquadrarBbox(imovel.bbox)}>Enquadrar no mapa</button>
          </section>
        ) : (
          <section>
            <h2>Camadas</h2>
            {grupos.map(([grupo, cs]) => (
              <div key={grupo} className="grupo">
                <h3>{grupo}</h3>
                {cs.map((c) => {
                  const foraDoZoom = zoom < c.minzoom || zoom >= (c.maxzoom >= 22 ? 99 : c.maxzoom);
                  return (
                    <label key={c.id} className={foraDoZoom ? "fora-zoom" : ""}>
                      <input type="checkbox" checked={visiveis.has(c.id)} onChange={() => alternar(c.id)} />
                      <span className="amostra" style={{ background: c.cor }} />
                      <span>
                        {c.nome}
                        {zoom < c.minzoom && <small> (aproxime: zoom ≥ {c.minzoom})</small>}
                      </span>
                    </label>
                  );
                })}
                {cs.some((c) => c.id === "foco_queimada") && visiveis.has("foco_queimada") && (
                  <div className="periodo">
                    <input type="date" value={periodo.ini} max={periodo.fim} onChange={(e) => setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
                    <span>até</span>
                    <input type="date" value={periodo.fim} min={periodo.ini} onChange={(e) => setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
                  </div>
                )}
              </div>
            ))}
          </section>
        )}
        <footer className="sub">zoom {zoom.toFixed(1)}</footer>
      </aside>
      <div ref={container} className="mapa" />
    </div>
  );
}

function htmlPopup(f: MapGeoJSONFeature): string {
  const esc = (v: unknown) => String(v ?? "").replace(/[&<>"]/g, (ch) => `&#${ch.charCodeAt(0)};`);
  const p = f.properties;
  if (f.source === "municipio_resumo")
    return `<strong>${esc(p.nome)}/${esc(p.uf)}</strong><br>${fmt.format(p.qtd_car)} imóveis no CAR<br>${fmt.format(p.area_car_ha)} ha declarados`;
  if (f.source === "foco_queimada" && Number(p.qtd) > 1)
    return `<strong>${fmt.format(p.qtd)} focos</strong> nesta área<br><small>aproxime para ver cada foco</small>`;
  return Object.entries(p)
    .map(([k, v]) => `<b>${esc(k)}</b>: ${esc(v)}`)
    .join("<br>");
}
