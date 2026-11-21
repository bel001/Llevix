// Listas fijas que usa el asistente.

export const IDIOMAS = [
  { valor: "es_ES.UTF-8", texto: "Español (España)" },
  { valor: "es_MX.UTF-8", texto: "Español (México)" },
  { valor: "es_AR.UTF-8", texto: "Español (Argentina)" },
  { valor: "es_CO.UTF-8", texto: "Español (Colombia)" },
  { valor: "es_CL.UTF-8", texto: "Español (Chile)" },
  { valor: "es_PE.UTF-8", texto: "Español (Perú)" },
  { valor: "es_VE.UTF-8", texto: "Español (Venezuela)" },
  { valor: "es_EC.UTF-8", texto: "Español (Ecuador)" },
  { valor: "es_UY.UTF-8", texto: "Español (Uruguay)" },
  { valor: "es_US.UTF-8", texto: "Español (Estados Unidos)" },
  { valor: "en_US.UTF-8", texto: "English (United States)" },
  { valor: "pt_BR.UTF-8", texto: "Português (Brasil)" },
];

export const ZONAS = [
  { valor: "Europe/Madrid", texto: "España (Madrid)" },
  { valor: "Atlantic/Canary", texto: "España (Canarias)" },
  { valor: "America/Mexico_City", texto: "México (Ciudad de México)" },
  { valor: "America/Tijuana", texto: "México (Tijuana)" },
  { valor: "America/Cancun", texto: "México (Cancún)" },
  { valor: "America/Argentina/Buenos_Aires", texto: "Argentina" },
  { valor: "America/Bogota", texto: "Colombia" },
  { valor: "America/Santiago", texto: "Chile" },
  { valor: "America/Lima", texto: "Perú" },
  { valor: "America/Caracas", texto: "Venezuela" },
  { valor: "America/Guayaquil", texto: "Ecuador" },
  { valor: "America/Montevideo", texto: "Uruguay" },
  { valor: "America/Asuncion", texto: "Paraguay" },
  { valor: "America/La_Paz", texto: "Bolivia" },
  { valor: "America/Guatemala", texto: "Guatemala" },
  { valor: "America/El_Salvador", texto: "El Salvador" },
  { valor: "America/Tegucigalpa", texto: "Honduras" },
  { valor: "America/Managua", texto: "Nicaragua" },
  { valor: "America/Costa_Rica", texto: "Costa Rica" },
  { valor: "America/Panama", texto: "Panamá" },
  { valor: "America/Havana", texto: "Cuba" },
  { valor: "America/Santo_Domingo", texto: "República Dominicana" },
  { valor: "America/Puerto_Rico", texto: "Puerto Rico" },
  { valor: "America/New_York", texto: "Estados Unidos (Este)" },
  { valor: "America/Chicago", texto: "Estados Unidos (Centro)" },
  { valor: "America/Denver", texto: "Estados Unidos (Montaña)" },
  { valor: "America/Los_Angeles", texto: "Estados Unidos (Pacífico)" },
  { valor: "America/Sao_Paulo", texto: "Brasil (São Paulo)" },
  { valor: "UTC", texto: "UTC (hora universal)" },
];

export const TECLADOS = [
  { valor: "es", texto: "Español (España)" },
  { valor: "latam", texto: "Español (Latinoamérica)" },
  { valor: "us", texto: "Inglés (Estados Unidos)" },
  { valor: "br", texto: "Portugués (Brasil)" },
];

// Zona horaria sugerida según el idioma elegido.
export const ZONA_POR_IDIOMA = {
  "es_ES.UTF-8": "Europe/Madrid",
  "es_MX.UTF-8": "America/Mexico_City",
  "es_AR.UTF-8": "America/Argentina/Buenos_Aires",
  "es_CO.UTF-8": "America/Bogota",
  "es_CL.UTF-8": "America/Santiago",
  "es_PE.UTF-8": "America/Lima",
  "es_VE.UTF-8": "America/Caracas",
  "es_EC.UTF-8": "America/Guayaquil",
  "es_UY.UTF-8": "America/Montevideo",
  "es_US.UTF-8": "America/New_York",
  "en_US.UTF-8": "America/New_York",
  "pt_BR.UTF-8": "America/Sao_Paulo",
};

export const TECLADO_POR_IDIOMA = {
  "es_ES.UTF-8": "es",
  "en_US.UTF-8": "us",
  "pt_BR.UTF-8": "br",
};

// Tecla del menú de arranque de una sola vez, por marca.
export const TECLAS_ARRANQUE = [
  { marca: "HP", tecla: "Esc y luego F9" },
  { marca: "Lenovo", tecla: "F12 (o el botón Novo)" },
  { marca: "Dell", tecla: "F12" },
  { marca: "Asus", tecla: "Esc (portátiles) o F8 (escritorio)" },
  { marca: "Acer", tecla: "F12" },
  { marca: "MSI", tecla: "F11" },
  { marca: "Toshiba / Dynabook", tecla: "F12" },
  { marca: "Samsung", tecla: "Esc o F10" },
  { marca: "Gigabyte", tecla: "F12" },
  { marca: "Apple (Intel)", tecla: "Mantener Option (⌥)" },
];

export function formatoBytes(b) {
  if (!b && b !== 0) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = b;
  while (v >= 1000 && i < u.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}

// Sugiere un nombre de usuario a partir del nombre completo: "Ana Pérez" → "ana".
export function sugerirUsuario(nombreCompleto) {
  const primero = (nombreCompleto || "").trim().split(/\s+/)[0] || "";
  const limpio = primero
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "");
  return /^[a-z]/.test(limpio) ? limpio.slice(0, 32) : "";
}
