<script>
  // Íconos de línea propios (SVG), sin bibliotecas externas.
  let { nombre, tam = 20 } = $props();

  const RUTAS = {
    check: "M5 12.5l4.5 4.5L19 7.5",
    usb: "M9 2h6v5H9zM7 7h10v9a5 5 0 0 1-10 0zM10.5 4h.01M13.5 4h.01",
    ssd: "M4 6h16v12H4zM7 10h10M7 14h6",
    "flecha-der": "M5 12h14M13 6l6 6-6 6",
    "flecha-izq": "M19 12H5M11 6l-6 6 6 6",
    ojo: "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z",
    "ojo-no": "M3 3l18 18M10.6 5.1A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3 3.9M6.6 6.6C3.8 8.3 2 12 2 12s3.5 7 10 7a9.8 9.8 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2",
    disco: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
    escudo: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM8.5 12l2.5 2.5 4.5-5",
    rayo: "M13 2L4 14h7l-1 8 9-12h-7z",
    refrescar: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
    alerta: "M12 3l10 18H2zM12 10v5M12 18h.01",
    candado: "M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4",
    usuario: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
    globo: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.5 3.8 5.5 3.8 9s-1.3 6.5-3.8 9c-2.5-2.5-3.8-5.5-3.8-9S9.5 5.5 12 3z",
    reloj: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2",
    teclado: "M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M7 14h10",
    descargar: "M12 4v11M7 10l5 5 5-5M5 20h14",
    escribir: "M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4",
    lupa: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4",
    engranaje: "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z",
    archivo: "M14 3H6v18h12V7zM14 3v4h4M9 13h6M9 17h6",
    mas: "M12 5v14M5 12h14",
    x: "M6 6l12 12M18 6L6 18",
  };
</script>

<svg
  width={tam}
  height={tam}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="1.8"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
>
  <path d={RUTAS[nombre] ?? ""} />
</svg>
