# Llevix

**Tu Linux en el bolsillo.** Llevix convierte una memoria USB o un disco externo (HDD,
SSD o NVMe en caja USB) en un Linux portátil y persistente que arranca en cualquier PC.

- Eliges la distribución, escribes tu usuario y contraseña, y el disco queda listo.
- Tus archivos y programas se conservan de una computadora a otra.
- La carpeta **Datos** también se abre desde Windows y desde un celular Android.
- Funciona con el **Arranque seguro (Secure Boot)** activado: no hay que tocar la BIOS.

> **Estado: beta.** Funciona en las pruebas automáticas; estamos probando en PCs reales.
> Si lo pruebas, [cuéntanos cómo te fue](docs/BETA.md).

<!-- GIF: el asistente del creador (pasos 1 a 3). Reemplazar por docs/img/creador.gif -->
<!-- GIF: arranque desde el USB hasta el escritorio. Reemplazar por docs/img/arranque.gif -->

## Descarga

1. Ve a la [última versión](https://github.com/bel001/Llevix/releases/latest).
2. Descarga **Llevix-Creador-…-setup.exe** (Windows 10 u 11).
3. Instálalo, ábrelo y sigue los 3 pasos.

¿Sin Windows? Descarga la imagen `.img.zst` de tu variante (y sus partes `.001`, `.002`…
si las tiene), únelas, descomprímelas y escríbelas con balenaEtcher o `dd`. Sin el creador
no se configura la cuenta: en Ubuntu (GNOME) la bienvenida te pide crearla; en las demás variantes entras con `llevix` / `llevix` y te pide cambiarla.

## Variantes

| Variante | Escritorio | Para |
| --- | --- | --- |
| Llevix, basado en Ubuntu 24.04 LTS | GNOME | PCs con 8 GB de RAM o más |
| Llevix, basado en Kubuntu 24.04 LTS | KDE Plasma | Parecido a Windows, 8 GB de RAM |
| Llevix, basado en Xubuntu 24.04 LTS | Xfce | **Ligera**, 4 GB de RAM |
| Llevix, basado en Lubuntu 24.04 LTS | LXQt | **Ligera**, PCs antiguas con 2–4 GB |
| Llevix, basado en Linux Mint 22 Cinnamon | Cinnamon | Fácil si vienes de Windows |
| Llevix, basado en Linux Mint 22 MATE | MATE | **Ligera**, clásica |
| Llevix, basado en Linux Mint 22 Xfce | Xfce | **Ligera** |

Cada variante trae su escritorio tal como lo hace la distribución. Llevix es un proyecto
independiente: no está afiliado a Canonical ni a Linux Mint.

## Requisitos

- Una memoria USB o disco externo de **32 GB o más** (mejor USB 3 o un SSD externo).
- Una PC x86_64 (Intel o AMD) de los últimos ~15 años, con UEFI o BIOS.
- Para crear el disco: Windows 10 u 11 y conexión a internet (descarga de 3 a 4 GB).

## Cómo arrancar

Conecta el disco, enciende la PC y pulsa la tecla del **menú de arranque de una sola vez**:
HP: Esc y F9 · Lenovo: F12 · Dell: F12 · Asus: Esc o F8 · Acer: F12 · MSI: F11 ·
Toshiba: F12 · Samsung: Esc o F10.

**No desactives Secure Boot.** En PCs con BitLocker, Windows podría pedirte la clave de
recuperación. Llevix arranca con Secure Boot activado.

## Preguntas frecuentes

**¿Borra mi Windows?** No. Llevix vive solo en el disco USB. Tu PC no se modifica.

**¿Se guardan mis archivos?** Sí. Todo lo que guardes (carpeta personal y **Datos**)
sigue ahí la próxima vez, en esta PC o en otra.

**¿Puedo ver mis archivos desde Windows o el celular?** Sí: la partición **LLEVIX**
(tu carpeta **Datos**) usa exFAT, que Windows, macOS y Android leen.

**La pantalla queda negra.** Reinicia y elige **«Llevix (modo gráficos seguros)»** en el menú.

**Actualicé y algo dejó de andar.** Antes de cada actualización, Llevix guarda un estado
del sistema. En el menú de arranque elige **«Llevix: volver a un estado anterior»**.
Tus archivos no se tocan.

**¿Qué pasa si desconecto el USB sin apagar?** El sistema usa btrfs y está probado para
resistir cortes de corriente. Igual, apaga siempre antes de desconectar.

**¿Es seguro?** Tu contraseña nunca se guarda en texto: el creador solo escribe su huella
cifrada (SHA-512). El creador nunca muestra ni escribe los discos internos de tu PC.

**¿Cuánto dura una memoria USB?** Llevix escribe lo menos posible (registros en RAM,
`/tmp` en RAM, compresión). Un SSD externo dura más y es más rápido.

## Desarrollo

| Carpeta | Contenido |
| --- | --- |
| `image/` | Construcción de las imágenes (bash + debootstrap) |
| `creator/` | Creador para Windows (Tauri 2 + Svelte, núcleo en Rust) |
| `tests/` | Pruebas en QEMU: arranque, primer arranque y resistencia |
| `tools/` | Herramientas (`check-env.sh`, `make-config.sh`, `manifest.sh`, `report.sh`) |
| `docs/` | Documentación, planes y bitácora |

Empieza por [CONTRIBUTING.md](CONTRIBUTING.md) y `./tools/check-env.sh`.

## Licencia

Pendiente de decidir (GPL-3.0 o MIT). Cada imagen incluye software de Ubuntu y Linux Mint
con sus propias licencias; el Release publica la lista exacta de paquetes y enlaces a su
código fuente.
