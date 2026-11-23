// Simulación SOLO para desarrollo en el navegador (ver puente.js). Nunca se usa en la app:
// no toca discos ni descarga nada; devuelve datos de ejemplo y un progreso falso.

const GB = 1_000_000_000;
const IMAGEN = 30_064_771_072;
const sha = "a".repeat(64);
const variante = (id, nombre, descripcion, ligera, tamano) => ({
  id, tipo: "escritorio", nombre, descripcion, ligera, base: id.split("-")[0],
  tamano_comprimido: tamano, tamano_imagen: IMAGEN, sha256: sha,
  partes: [], bmap_url: "", bmap_sha256: sha,
});

const MANIFEST = {
  formato: 1,
  version: "v0.1.0-simulación",
  variantes: [
    variante("ubuntu-24.04", "Llevix, basado en Ubuntu 24.04 LTS", "El escritorio GNOME de Ubuntu. Moderno y completo; recomendado con 8 GB de RAM o más.", false, 3.8 * GB),
    variante("kubuntu-24.04", "Llevix, basado en Kubuntu 24.04 LTS", "KDE Plasma: muy configurable, con aspecto parecido a Windows. Recomendado con 8 GB de RAM.", false, 5.4 * GB),
    variante("xubuntu-24.04", "Llevix, basado en Xubuntu 24.04 LTS", "Xfce: liviano y estable. Bueno para PCs con 4 GB de RAM.", true, 3.6 * GB),
    variante("lubuntu-24.04", "Llevix, basado en Lubuntu 24.04 LTS", "LXQt: el más liviano. Para PCs antiguas con 2 a 4 GB de RAM.", true, 4.7 * GB),
    variante("mint-22-cinnamon", "Llevix, basado en Linux Mint 22 Cinnamon", "Cinnamon: fácil para quien viene de Windows. Recomendado con 4 GB de RAM o más.", false, 3.6 * GB),
    variante("mint-22-mate", "Llevix, basado en Linux Mint 22 MATE", "MATE: clásico y liviano. Bueno para PCs con 4 GB de RAM.", true, 3.6 * GB),
    variante("mint-22-xfce", "Llevix, basado en Linux Mint 22 Xfce", "Xfce: el Mint más liviano. Para PCs con 2 a 4 GB de RAM.", true, 3.4 * GB),
    variante("debian-13-gnome", "Llevix, basado en Debian 13 GNOME", "GNOME de Debian: estable y sobrio. Recomendado con 8 GB de RAM.", false, 3.2 * GB),
    variante("zorin-18", "Llevix, basado en Zorin OS 18 Core", "Zorin OS: escritorio pulido con aspecto parecido a Windows o macOS. Recomendado con 8 GB de RAM.", false, 4.1 * GB),
    { ...variante("instalador", "Llevix: instalador de ISO", "", false, 0.4 * GB), tipo: "instalador" },
  ],
};

const DISCOS = {
  aptos: [
    {
      numero: 2, modelo: "SanDisk Ultra Fit", tamano: 64 * GB, bus: "usb", extraible: true, sector_logico: 512,
      es_sistema: false, es_arranque: false, particiones: 1,
      volumenes: [{ letra: "E:", etiqueta: "FOTOS", sistema_archivos: "exFAT", tamano: 64 * GB, usado: 12.3 * GB, muestra: ["Vacaciones 2025", "Cumple Ana", "Documentos"] }],
    },
    {
      numero: 3, modelo: "Samsung T7 SSD", tamano: 500 * GB, bus: "usb", extraible: false, sector_logico: 512,
      es_sistema: false, es_arranque: false, particiones: 0, volumenes: [],
    },
  ],
  chicos: [
    { numero: 4, modelo: "Kingston DataTraveler", tamano: 16 * GB, bus: "usb", volumenes: [], particiones: 1 },
  ],
};

const oyentes = {};
const esperar = (ms) => new Promise((r) => setTimeout(r, ms));
const emitir = (evento, payload) => (oyentes[evento] || []).forEach((f) => f({ payload }));

export async function listen(evento, f) {
  (oyentes[evento] ||= []).push(f);
  return () => (oyentes[evento] = oyentes[evento].filter((x) => x !== f));
}

export async function open() {
  await esperar(300);
  return "C:\\Users\\ana\\Descargas\\linuxmint-22.3-cinnamon-64bit.iso";
}

async function simularCreacion(conIso) {
  const etapas = [
    ["descarga", 3.6 * GB, 40],
    ["verificando_descarga", 3.6 * GB, 15],
    ["preparando", 0, 5],
    ["prueba_disco", 64 * 1024 * 1024, 10],
    ["escritura", 4.4 * GB, 40],
    ["verificacion", 4.4 * GB, 20],
    ...(conIso ? [["iso", 3 * 2.9 * GB, 25]] : []),
    ["config", 1, 4],
  ];
  for (const [etapa, total, pasos] of etapas) {
    for (let i = 0; i <= pasos; i++) {
      emitir("llevix://progreso", { etapa, hechos: (total * i) / pasos, total });
      await esperar(90);
    }
  }
  emitir("llevix://fin", { ok: true, mensaje: "Listo" });
}

export async function invoke(comando, args = {}) {
  await esperar(250);
  switch (comando) {
    case "obtener_manifest":
      await esperar(500);
      return MANIFEST;
    case "analizar_iso":
      await esperar(700);
      return { nombre: "Linux Mint 22.3 \"Zena\" Cinnamon", tipo: "squashfs", tamano: 2.9 * GB };
    case "preparar_cuenta":
      return { usuario: args.datos.usuario, hostname: `llevix-${args.datos.usuario}` };
    case "listar_discos":
      await esperar(600);
      return DISCOS;
    case "crear_usb":
      simularCreacion(!!args.iso);
      return null;
    case "cancelar":
      return null;
    default:
      throw new Error(`comando desconocido en la simulación: ${comando}`);
  }
}
