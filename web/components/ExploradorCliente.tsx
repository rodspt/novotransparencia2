"use client";

import dynamic from "next/dynamic";

// MapLibre depende de window/WebGL: renderiza só no navegador.
const Explorador = dynamic(() => import("./Explorador"), { ssr: false });

export default Explorador;
