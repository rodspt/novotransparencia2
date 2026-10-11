"use client";

import maplibregl, { type Map as MlMap, type MapGeoJSONFeature } from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import { api, type Bbox, type Camada, type Imovel, type ResultadoBusca, type Sobreposicao } from "@/lib/api";
import {
  adicionarCamadas, adicionarDestaques, COR_DESTAQUE, FILTRO_NENHUM, idsCamadasMapa, idsDestaque, OPACIDADE_PREENCHIMENTO,
  propOpacidade, urlTiles, type IdsDestaque, type Periodo,
} from "@/lib/camadas-mapa";

const ESTILO_BASE = "https://tiles.openfreemap.org/styles/positron";
const fmt = new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 2 });

// Focos do dw vão até o fim do ano anterior: o padrão é esse ano inteiro.
function periodoPadrao(): Periodo {
  const ano = new Date().getFullYear() - 1;
  return { ini: `${ano}-01-01`, fim: `${ano}-12-31` };
}

export default function Explorador() {
  const raiz = useRef<HTMLDivElement>(null);
  const container = useRef<HTMLDivElement>(null);
  const coordRef = useRef<HTMLSpanElement>(null);  // atualizado direto no DOM: mousemove não re-renderiza a página
  const mapRef = useRef<MlMap | null>(null);
  const selecionadoRef = useRef<MapGeoJSONFeature | null>(null);
  // destaque piscando: camada cuja feição clicada está filtrada + se o GeoJSON (imóvel da busca) está em uso
  const destaqueRef = useRef<IdsDestaque | null>(null);
  // camada GeoJSON "destaque": imóvel do painel (fica contornado) ou feição sem id clicada (pisca)
  const geojsonRef = useRef<{ origem: "imovel" | "feicao"; piscando: boolean } | null>(null);
  const animacaoRef = useRef<number | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
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
  const [painelAberto, setPainelAberto] = useState(true);
  const [carregando, setCarregando] = useState(false);
  const [filtro, setFiltro] = useState("");
  const [gruposFechados, setGruposFechados] = useState<Set<string>>(new Set());
  const [copiado, setCopiado] = useState(false);

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
      dragRotate: false,      // mapa sempre com o norte para cima: sem bússola, a tela cheia fica logo abaixo do + / −
      pitchWithRotate: false,
    });
    map.touchZoomRotate.disableRotation();
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
    // tela cheia logo abaixo do + / − (a página inteira: painel e busca continuam disponíveis)
    map.addControl(new maplibregl.FullscreenControl({ container: raiz.current! }), "top-right");
    map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-right");
    map.on("dataloading", () => setCarregando(true));
    map.on("idle", () => setCarregando(false));
    map.on("mousemove", (e) => {
      if (coordRef.current)
        coordRef.current.textContent = `${e.lngLat.lat.toFixed(5)}, ${e.lngLat.lng.toFixed(5)}`;
    });
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
      // imóvel aberto pela busca (geometria vinda da API) ou feição sem id clicada
      map.addSource("destaque", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      map.addLayer({ id: "destaque-halo", type: "line", source: "destaque", layout: { "line-join": "round" },
        paint: { "line-color": "#fff", "line-width": 7, "line-opacity": 0.9 } });
      map.addLayer({ id: "destaque", type: "line", source: "destaque", layout: { "line-join": "round" },
        paint: { "line-color": COR_DESTAQUE, "line-width": 3.5 } });
      setMapaPronto(true);
    });
    map.on("zoomend", () => setZoom(map.getZoom()));
    mapRef.current = map;
    return () => map.remove();
  }, []);

  // painel recolhido/aberto muda o tamanho do mapa
  useEffect(() => {
    const t = setTimeout(() => mapRef.current?.resize(), 220);
    return () => clearTimeout(t);
  }, [painelAberto]);

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
    adicionarDestaques(map, camadas);  // acima de todas as camadas de dados
    map.moveLayer("destaque-halo");
    map.moveLayer("destaque");

    const clicaveis = camadas.flatMap((c) => idsCamadasMapa(c)).filter((id) => !id.endsWith("-line"));
    const aoClicar = (e: maplibregl.MapMouseEvent) => {
      // clique sobre a linha que está piscando: só desliga o destaque
      if (cliqueNaLinhaPiscando(e.point)) {
        limparDestaqueFeicao();
        pararGeojson();
        popupRef.current?.remove();
        return;
      }
      const [f] = map.queryRenderedFeatures(e.point, { layers: clicaveis.filter((id) => map.getLayer(id)) });
      if (!f) {
        limparDestaqueFeicao();
        pararGeojson();
        return;
      }
      destacarFeicao(f);
      if (f.source === "sicar") {
        marcarSelecionado(f);
        void abrirImovel(String(f.properties.cod_imovel));
      } else {
        popupRef.current = new maplibregl.Popup({ maxWidth: "340px", className: "popup" })
          .setLngLat(e.lngLat)
          .setHTML(htmlPopup(f, camadas.find((c) => c.id === f.source)))
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
      if (animacaoRef.current !== null) cancelAnimationFrame(animacaoRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mapaPronto, camadas]);

  // visibilidade
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !mapaPronto) return;
    for (const c of camadas) {
      const { preenchimento, halo, linha } = idsDestaque(c);
      for (const id of [...idsCamadasMapa(c), preenchimento, halo, linha].filter(Boolean) as string[])
        if (map.getLayer(id)) map.setLayoutProperty(id, "visibility", visiveis.has(c.id) ? "visible" : "none");
    }
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

  // ---- destaque piscando -------------------------------------------------------------------
  function animarDestaque() {
    if (animacaoRef.current !== null) return;  // já está rodando
    const map = mapRef.current!;
    const inicio = performance.now();
    let ultimo = 0;
    const passo = (t: number) => {
      const d = destaqueRef.current;
      const alvos = [d?.linha, d?.preenchimento, geojsonRef.current?.piscando ? "destaque" : undefined].filter(Boolean) as string[];
      if (alvos.length === 0) {
        animacaoRef.current = null;
        return;
      }
      if (t - ultimo > 60) {  // ~16 quadros/s bastam para o efeito
        const opacidade = 0.1 + 0.9 * (0.5 + 0.5 * Math.cos((t - inicio) / 160));  // ~1 piscada por segundo
        for (const id of alvos) {
          if (!map.getLayer(id)) continue;
          const prop = propOpacidade(map, id);
          map.setPaintProperty(id, prop, prop === "fill-opacity" ? opacidade * OPACIDADE_PREENCHIMENTO : opacidade);
        }
        ultimo = t;
      }
      animacaoRef.current = requestAnimationFrame(passo);
    };
    animacaoRef.current = requestAnimationFrame(passo);
  }

  /** O clique caiu (com tolerância de alguns pixels) na linha/anel que está piscando? */
  function cliqueNaLinhaPiscando(ponto: maplibregl.Point): boolean {
    const map = mapRef.current!;
    const d = destaqueRef.current;
    const camadas = [d?.halo, d?.linha, ...(geojsonRef.current?.piscando ? ["destaque-halo", "destaque"] : [])]
      .filter((id): id is string => !!id && !!map.getLayer(id));
    if (camadas.length === 0) return false;
    const tol = 5;
    const caixa: [maplibregl.PointLike, maplibregl.PointLike] = [[ponto.x - tol, ponto.y - tol], [ponto.x + tol, ponto.y + tol]];
    return map.queryRenderedFeatures(caixa, { layers: camadas }).length > 0;
  }

  function destacarFeicao(f: MapGeoJSONFeature) {
    const map = mapRef.current!;
    limparDestaqueFeicao();
    pararGeojson();
    const camada = camadas.find((c) => c.id === f.source);
    if (camada && f.id !== undefined) {
      const ids = idsDestaque(camada);
      const filtro: maplibregl.FilterSpecification = ["==", ["id"], f.id as number];
      for (const id of [ids.preenchimento, ids.halo, ids.linha]) if (id) map.setFilter(id, filtro);
      destaqueRef.current = ids;
    } else {
      // camada sem id de feição: usa a geometria do próprio tile
      definirGeojson(f.geometry, "feicao", camada?.cor);
    }
    animarDestaque();
  }

  function definirGeojson(geometria: GeoJSON.Geometry | null, origem: "imovel" | "feicao", cor = COR_DESTAQUE) {
    const map = mapRef.current;
    const src = map?.getSource("destaque") as maplibregl.GeoJSONSource | undefined;
    if (geometria && map?.getLayer("destaque")) map.setPaintProperty("destaque", "line-color", cor);
    src?.setData(geometria ? { type: "Feature", geometry: geometria, properties: {} } : { type: "FeatureCollection", features: [] });
    geojsonRef.current = geometria ? { origem, piscando: true } : null;
  }

  /** Feição sem id some; contorno do imóvel do painel fica, mas parado. */
  function pararGeojson() {
    const atual = geojsonRef.current;
    if (!atual) return;
    if (atual.origem === "feicao") return definirGeojson(null, "feicao");
    atual.piscando = false;
    mapRef.current?.setPaintProperty("destaque", "line-opacity", 1);
  }

  function limparDestaqueFeicao() {
    const map = mapRef.current;
    const ids = destaqueRef.current;
    if (map && ids) {
      for (const id of [ids.preenchimento, ids.halo, ids.linha]) if (id && map.getLayer(id)) map.setFilter(id, FILTRO_NENHUM);
    }
    destaqueRef.current = null;
  }

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
      definirGeojson(im.geometria, "imovel", camadas.find((c) => c.id === "sicar")?.cor);
      animarDestaque();
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
    limparDestaqueFeicao();
    definirGeojson(null, "imovel");
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

  /** Liga ou desliga várias camadas de uma vez (todas, as filtradas ou as de um grupo). */
  function definirVisiveis(ids: string[], ligar: boolean) {
    setVisiveis((v) => {
      const n = new Set(v);
      for (const id of ids) {
        if (ligar) n.add(id);
        else n.delete(id);
      }
      return n;
    });
  }

  function alternarGrupo(grupo: string) {
    setGruposFechados((g) => {
      const n = new Set(g);
      if (n.has(grupo)) n.delete(grupo);
      else n.add(grupo);
      return n;
    });
  }

  async function copiarCodigo(cod: string) {
    try {
      await navigator.clipboard.writeText(cod);
      setCopiado(true);
      setTimeout(() => setCopiado(false), 1500);
    } catch {
      /* navegador sem permissão de área de transferência */
    }
  }

  const termo = filtro.trim().toLowerCase();
  const gruposFiltrados = grupos
    .map(([g, cs]) => [g, termo ? cs.filter((c) => `${c.nome} ${c.fonte ?? ""}`.toLowerCase().includes(termo)) : cs] as const)
    .filter(([, cs]) => cs.length > 0);
  const legendaMunicipio = visiveis.has("municipio_resumo") && zoom < 10;
  const idsListados = gruposFiltrados.flatMap(([, cs]) => cs.map((c) => c.id));
  const todasMarcadas = idsListados.length > 0 && idsListados.every((id) => visiveis.has(id));

  return (
    <div ref={raiz} className={`explorador ${painelAberto ? "" : "painel-recolhido"}`}>
      <aside className="painel" aria-hidden={!painelAberto}>
        <header className="marca">
          <span className="marca-icone" aria-hidden><Icone nome="folha" /></span>
          <div>
            <h1>Novo Transparência</h1>
            <p>Bases fundiárias e ambientais do Brasil</p>
          </div>
          <button className="icone-btn" onClick={() => setPainelAberto(false)} title="Recolher painel" aria-label="Recolher painel">
            <Icone nome="recolher" />
          </button>
        </header>

        <div className="campo-busca">
          <Icone nome="lupa" />
          <input
            placeholder="Código do CAR ou nome do imóvel"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            aria-label="Buscar imóvel"
          />
          {busca && (
            <button className="icone-btn limpar" onClick={() => setBusca("")} aria-label="Limpar busca"><Icone nome="x" /></button>
          )}
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
                    <code>{r.cod_imovel}</code>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>

        {erro && <p className="erro">{erro}</p>}

        <div className="painel-corpo">
          {imovel ? (
            <section className="imovel">
              <button className="voltar" onClick={fecharImovel}><Icone nome="voltar" /> Camadas</button>
              <div className="imovel-titulo">
                <h2>{imovel.nome_imovel ?? "Imóvel sem denominação"}</h2>
                {imovel.status_imovel && <span className={`selo ${classeStatus(imovel.status_imovel)}`}>{imovel.status_imovel}</span>}
              </div>
              <div className="codigo">
                <code>{imovel.cod_imovel}</code>
                <button className="icone-btn" onClick={() => copiarCodigo(imovel.cod_imovel)} title="Copiar código">
                  <Icone nome={copiado ? "ok" : "copiar"} />
                </button>
              </div>

              <div className="metricas">
                <div><span>Área</span><strong>{fmt.format(imovel.area ?? 0)}</strong><small>hectares</small></div>
                <div><span>Módulos fiscais</span><strong>{fmt.format(imovel.m_fiscal ?? 0)}</strong><small>&nbsp;</small></div>
              </div>

              <dl className="detalhes">
                <dt>Município</dt><dd>{imovel.municipio}/{imovel.uf}</dd>
                <dt>Tipo</dt><dd>{imovel.tipo_imovel ?? "—"}</dd>
                <dt>Condição</dt><dd>{imovel.condicao ?? "—"}</dd>
                <dt>Proprietário</dt>
                <dd>
                  {imovel.nome_proprietario ?? (imovel.cpf_cnpj_proprietario ? "" : "—")}
                  {imovel.cpf_cnpj_proprietario && <code> {imovel.cpf_cnpj_proprietario}</code>}
                </dd>
              </dl>

              <div className="secao-titulo">
                <h3>Sobreposições</h3>
                <button className="link" onClick={() => enquadrarBbox(imovel.bbox)}><Icone nome="mira" /> Enquadrar</button>
              </div>
              {sobreposicoes === null ? (
                <p className="vazio"><span className="girando" /> Cruzando com as bases…</p>
              ) : (
                <ul className="sobreposicoes">
                  {[...sobreposicoes]
                    .sort((a, b) => Number((b.qtd ?? 0) > 0) - Number((a.qtd ?? 0) > 0))
                    .map((s) => {
                      const cor = camadas.find((c) => c.id === s.camada)?.cor ?? "#adb5bd";
                      const tem = (s.qtd ?? 0) > 0;
                      return (
                        <li key={s.camada} className={tem ? "tem" : ""}>
                          <span className="ponto-cor" style={{ background: cor }} />
                          <span className="nome">{s.nome}</span>
                          {s.qtd == null ? (
                            <span className="selo cinza" title="O cálculo excedeu o tempo limite">n/d</span>
                          ) : tem ? (
                            <span className="selo alerta">
                              {s.qtd}{s.area_ha != null ? ` · ${fmt.format(s.area_ha)} ha` : ""}
                            </span>
                          ) : (
                            <span className="zero">0</span>
                          )}
                        </li>
                      );
                    })}
                </ul>
              )}
            </section>
          ) : (
            <section className="camadas">
              <div className="secao-titulo">
                <h2>Camadas</h2>
                <span className="contagem">{visiveis.size} ativas</span>
              </div>
              <div className="acoes-camadas">
                <button className="link" onClick={() => definirVisiveis(idsListados, !todasMarcadas)} disabled={idsListados.length === 0}>
                  <Icone nome={todasMarcadas ? "x" : "ok"} />
                  {todasMarcadas ? "Desmarcar todas" : "Marcar todas"}
                  {termo && " as filtradas"}
                </button>
              </div>
              <input className="filtro" placeholder="Filtrar camadas…" value={filtro} onChange={(e) => setFiltro(e.target.value)} />
              {gruposFiltrados.map(([grupo, cs]) => {
                const fechado = gruposFechados.has(grupo) && !termo;
                const ativas = cs.filter((c) => visiveis.has(c.id)).length;
                return (
                  <div key={grupo} className={`grupo ${fechado ? "fechado" : ""}`}>
                    <div className="grupo-cabecalho">
                      <button className="grupo-abrir" onClick={() => alternarGrupo(grupo)} aria-expanded={!fechado}>
                        <Icone nome="seta" />
                        <span>{grupo}</span>
                        {ativas > 0 && <span className="contagem">{ativas}/{cs.length}</span>}
                      </button>
                      <CaixaGrupo
                        marcado={ativas === cs.length}
                        parcial={ativas > 0 && ativas < cs.length}
                        rotulo={`${ativas === cs.length ? "Desmarcar" : "Marcar"} todas de ${grupo}`}
                        onChange={() => definirVisiveis(cs.map((c) => c.id), ativas < cs.length)}
                      />
                    </div>
                    {!fechado && (
                      <ul>
                        {cs.map((c) => {
                          const foraDoZoom = zoom < c.minzoom || zoom >= (c.maxzoom >= 22 ? 99 : c.maxzoom);
                          return (
                            <li key={c.id} className={foraDoZoom ? "fora-zoom" : ""}>
                              <label>
                                <Amostra camada={c} />
                                <span className="nome">
                                  {c.nome}
                                  {c.fonte && <small>{c.fonte}</small>}
                                </span>
                                {zoom < c.minzoom && <span className="dica-zoom" title="Aproxime o mapa para ver">zoom {c.minzoom}+</span>}
                                <input type="checkbox" className="interruptor" checked={visiveis.has(c.id)} onChange={() => alternar(c.id)} />
                              </label>
                              {c.id === "foco_queimada" && visiveis.has(c.id) && (
                                <div className="periodo">
                                  <input type="date" value={periodo.ini} max={periodo.fim}
                                    onChange={(e) => setPeriodo((p) => ({ ...p, ini: e.target.value }))} aria-label="Início do período" />
                                  <span>até</span>
                                  <input type="date" value={periodo.fim} min={periodo.ini}
                                    onChange={(e) => setPeriodo((p) => ({ ...p, fim: e.target.value }))} aria-label="Fim do período" />
                                </div>
                              )}
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                );
              })}
              {gruposFiltrados.length === 0 && <p className="vazio">Nenhuma camada com “{filtro}”.</p>}
            </section>
          )}
        </div>
      </aside>

      <main className="area-mapa">
        <div ref={container} className="mapa" />
        {!painelAberto && (
          <button className="abrir-painel" onClick={() => setPainelAberto(true)} title="Abrir painel">
            <Icone nome="camadas" /> Camadas
          </button>
        )}
        <div className="status-mapa">
          {carregando && <span className="girando" title="Carregando dados" />}
          <span>zoom {zoom.toFixed(1)}</span>
          <span ref={coordRef} className="coordenadas" />
        </div>
        {legendaMunicipio && (
          <div className="legenda">
            <strong>Imóveis no CAR por município</strong>
            <ul>
              {[["#f1f3f5", "0"], ["#d3f9d8", "1 – 99"], ["#8ce99a", "100 – 999"], ["#40c057", "1.000 – 4.999"], ["#2b8a3e", "5.000 ou mais"]].map(([cor, rot]) => (
                <li key={rot}><span style={{ background: cor }} />{rot}</li>
              ))}
            </ul>
            <small>Aproxime (zoom 10+) para ver cada imóvel</small>
          </div>
        )}
      </main>
    </div>
  );
}

/** Caixa do grupo: marcada (todas), parcial (algumas) ou vazia (nenhuma). */
function CaixaGrupo({ marcado, parcial, rotulo, onChange }: { marcado: boolean; parcial: boolean; rotulo: string; onChange: () => void }) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = parcial;
  }, [parcial]);
  return <input ref={ref} type="checkbox" className="caixa-grupo" checked={marcado} onChange={onChange} title={rotulo} aria-label={rotulo} />;
}

function classeStatus(status: string): string {
  const s = status.toUpperCase();
  if (s.startsWith("ATIV")) return "verde";
  if (s.startsWith("PEND") || s.startsWith("SUSP")) return "amarelo";
  if (s.startsWith("CANC")) return "vermelho";
  return "cinza";
}

function Amostra({ camada }: { camada: Camada }) {
  if (camada.tipo_geom === "linha")
    return <span className="amostra linha" style={{ borderColor: camada.cor }} aria-hidden />;
  if (camada.tipo_geom === "ponto")
    return <span className="amostra ponto" style={{ background: camada.cor }} aria-hidden />;
  return <span className="amostra area" style={{ background: `${camada.cor}55`, borderColor: camada.cor }} aria-hidden />;
}

const ICONES: Record<string, string> = {
  lupa: "M11 4a7 7 0 1 0 4.2 12.6l4.1 4.1 1.4-1.4-4.1-4.1A7 7 0 0 0 11 4zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10z",
  x: "M6.4 5 5 6.4 10.6 12 5 17.6 6.4 19l5.6-5.6 5.6 5.6 1.4-1.4-5.6-5.6L19 6.4 17.6 5 12 10.6z",
  seta: "M9 6l6 6-6 6-1.4-1.4L12.2 12 7.6 7.4z",
  voltar: "M15 6 9 12l6 6 1.4-1.4L11.8 12l4.6-4.6z",
  copiar: "M8 3h10a2 2 0 0 1 2 2v12h-2V5H8zM5 7h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2zm0 2v10h10V9z",
  ok: "M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z",
  mira: "M11 2h2v3.1A7 7 0 0 1 18.9 11H22v2h-3.1A7 7 0 0 1 13 18.9V22h-2v-3.1A7 7 0 0 1 5.1 13H2v-2h3.1A7 7 0 0 1 11 5.1zm1 5a5 5 0 1 0 0 10 5 5 0 0 0 0-10zm0 3a2 2 0 1 1 0 4 2 2 0 0 1 0-4z",
  recolher: "M4 5h2v14H4zm11.6 1.4L14.2 5 7.2 12l7 7 1.4-1.4L10 12z",
  camadas: "M12 3 2 8.5l10 5.5 10-5.5zM4.3 12.2 2 13.5 12 19l10-5.5-2.3-1.3L12 16.5z",
  folha: "M20 4c-8 0-14 4-14 11 0 1.6.4 3 1 4.2l-2.3 2.3 1.4 1.4 2.3-2.3c1.2.6 2.6 1 4.2 1 7 0 11-6 11-14V4zm-8.6 14c-.9 0-1.8-.2-2.5-.5l6.8-6.8-1.4-1.4-6.8 6.8A6 6 0 0 1 7 15c0-5 4-8.2 11-8.9-.6 7.6-3.6 11.9-6.6 11.9z",
};

function Icone({ nome }: { nome: keyof typeof ICONES }) {
  return (
    <svg className="icone" viewBox="0 0 24 24" width="18" height="18" aria-hidden>
      <path d={ICONES[nome]} fill="currentColor" />
    </svg>
  );
}

// ---- popup das camadas -------------------------------------------------------------------------
const ROTULOS: Record<string, string> = {
  nome: "Nome", projeto: "Projeto", cd_sipra: "Código SIPRA", nu_familia: "Famílias", etnia: "Etnia", classe: "Classe",
  data: "Data", infracao: "Infração", num_auto_infracao: "Auto de infração", numero_embargo: "Nº do embargo",
  fonte: "Fonte", processo: "Processo", substancia: "Substância", fase: "Fase", ano_referencia: "Ano de referência",
  nr_ref_bacen: "Referência BACEN", ano_origem: "Ano", codigo_rodovia: "Rodovia", jurisdicao: "Jurisdição",
  extensao_km: "Extensão (km)", especie: "Espécie", qtd: "Focos", status: "Situação", tipo: "Tipo", natureza: "Natureza",
  qrcode: "QR code", nm_area: "Denominação", cod_imovel: "Código CAR", uf: "UF", area_ha: "Área (ha)",
};
const NUMERICOS = new Set(["area_ha", "extensao_km", "nu_familia", "qtd"]);

function htmlPopup(f: MapGeoJSONFeature, camada?: Camada): string {
  const esc = (v: unknown) => String(v ?? "").replace(/[&<>"]/g, (ch) => `&#${ch.charCodeAt(0)};`);
  const p = f.properties;
  const cabecalho = `<header><span style="background:${esc(camada?.cor ?? "#868e96")}"></span>${esc(camada?.nome ?? f.source)}</header>`;
  if (f.source === "municipio_resumo")
    return `${cabecalho}<h4>${esc(p.nome)}/${esc(p.uf)}</h4>
      <dl><dt>Imóveis no CAR</dt><dd>${fmt.format(p.qtd_car)}</dd><dt>Área declarada</dt><dd>${fmt.format(p.area_car_ha)} ha</dd></dl>`;
  if (f.source === "foco_queimada" && Number(p.qtd) > 1)
    return `${cabecalho}<h4>${fmt.format(p.qtd)} focos nesta área</h4><p>Aproxime o mapa para ver cada foco.</p>`;
  const titulo = p.nome ?? p.nm_area ?? p.projeto ?? p.classe ?? p.processo;
  const linhas = Object.entries(p)
    .filter(([k, v]) => v !== null && v !== "" && k !== "uf_id")
    .filter(([k, v]) => !(titulo && v === titulo && ["nome", "nm_area", "projeto"].includes(k)))
    .map(([k, v]) => {
      const rotulo = ROTULOS[k] ?? k.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
      const valor = NUMERICOS.has(k) && !Number.isNaN(Number(v)) ? fmt.format(Number(v)) : esc(v);
      return `<dt>${esc(rotulo)}</dt><dd>${valor}</dd>`;
    })
    .join("");
  return `${cabecalho}${titulo ? `<h4>${esc(titulo)}</h4>` : ""}<dl>${linhas}</dl>`;
}
