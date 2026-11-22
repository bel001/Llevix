# Bitácora de Llevix

Lo más reciente arriba. Cada fase anota qué se hizo, qué se decidió y qué quedó pendiente.

## Beta — Escritorio completo (2026-11-22)

**Problema reportado por el dueño** (Mint, en otras PCs): sin WiFi, sin sonido, sin
navegador y "la configuración de APT está corrupta".

**Causas**
- Mint MATE/Xfce se armaban con `mint-meta-*`, que no incluye red ni sonido (la ISO de
  Mint los agrega por otro lado). Ninguna variante traía navegador.
- Los repositorios de Mint estaban en formato Ubuntu; el Gestor de actualizaciones de
  Mint exige `official-package-repositories.list`.
- Las pruebas solo miraban que apareciera la pantalla de inicio de sesión.

**Arreglo**
- Mint se instala con la lista de paquetes de su ISO oficial (`tools/manifiesto-iso.sh`,
  workflow `manifiestos`, `image/distros/paquetes/`), con repositorios y prioridades
  iguales a los de Mint.
- Firefox (en español) del repositorio oficial de Mozilla en las variantes de Ubuntu;
  Xubuntu pasa a `xubuntu-desktop` completo; Ubuntu suma `gnome-software`.
- `build.sh` falla si falta red, WiFi, icono de red, sonido, navegador, terminal o archivos.
- QEMU con tarjeta de sonido; nuevas comprobaciones: red conectada, sonido, Firefox,
  `apt-get update` sin errores y formato de Mint. Las 7 variantes en verde.

**Decidido**: A + B (más distros y "Trae tu ISO"), ver docs/planes/catalogo-e-iso-propia.md.

## Fase 6 — Preparación de la beta (2026-11-21)

**Qué se hizo**
- `tools/report.sh` (en la imagen como `/usr/lib/llevix/report.sh`): reporte de
  diagnóstico sin datos personales, guardado en `~/Datos`. Probado en las 7 variantes.
- Plantillas de issues en español: "Funcionó en mi PC", "No arranca", "Algo no funciona".
- `docs/BETA.md` (guía para testers) y README con descarga, requisitos, variantes,
  cómo arrancar, preguntas frecuentes y lugares marcados para los GIFs.
- `PENDIENTES.md` con las tareas humanas de la beta.
- Release: el instalador del creador se busca dentro de las subcarpetas del artefacto
  (`v0.0.2-test` falló en ese paso; `v0.0.3-test` lo verifica).

**Estado**
- El piloto automático se detiene aquí, como indica AUTOPILOTO.md: lo que sigue necesita
  PCs reales, testers y decisiones del dueño (ver PENDIENTES.md).

## Fase 5 — Creador para Windows (2026-11-21)

**Qué se hizo**
- `creator/nucleo` (Rust): manifest, descarga con reanudación y SHA256 por parte y total,
  lectura del `.bmap` (compatible con `bmaptool`, incluida su suma interna), escritura
  zstd en streaming solo de los bloques con datos (con suma por rango y verificación
  final), GPT + escritura de `llevix-config.json` en la ESP con `fatfs` sin montar,
  config con hash SHA-512 (`sha-crypt`) y las mismas reglas que `firstboot.sh`, filtro
  de discos (solo USB, nunca el del sistema) y acceso a discos de Windows por FFI.
- `creator/src-tauri` + `creator/src`: app Tauri 2 + Svelte 5 en español con el asistente
  de 3 pasos, doble confirmación si el disco tiene datos, progreso, cancelación y
  pantalla final con teclas por marca y el aviso de Secure Boot/BitLocker. Pide
  administrador por manifiesto.
- `.github/workflows/creador.yml`: 32 pruebas del núcleo en Linux y en Windows (en
  Windows incluye la enumeración real de discos, que nunca ofrece ni abre el del sistema),
  `tauri build` → instalador `.exe` (NSIS, 3 MB) y `.msi` (4,3 MB).
- Prueba de punta a punta (`tests/creador-e2e.sh`): el núcleo descarga la versión
  publicada, la escribe en un disco simulado de 32 GiB con una cuenta, y QEMU arranca
  ese disco con Secure Boot: cuenta, contraseña, idioma, zona y datos correctos.
- `release.yml` agrega el instalador del creador al Release.

**Decisiones**
- FFI propio a kernel32 en lugar de la biblioteca `windows` (menos dependencias, sin
  cambios de API entre versiones).
- Se borran el primer y el último MiB del disco antes de escribir (copia vieja de la GPT).
- Discos con sectores lógicos de 4096 bytes no se ofrecen (la imagen usa 512).
- La búsqueda de versión usa la última estable y, si no hay, la pre-release más nueva.

**Pendiente**
- Prueba humana: crear un USB real con el creador y arrancarlo (PENDIENTES.md).
- Firma del instalador (Windows SmartScreen avisará mientras no esté firmado).
## Fase 4 — Publicación automática (2026-11-21)

**Qué se hizo**
- `build.yml` se puede reutilizar (`workflow_call`) y ahora deja por variante: imagen
  comprimida, `.sha256`, `.bmap` (`bmaptool create`), tamaño y lista de paquetes.
- `tools/manifest.sh` genera `manifest.json` (formato 1) a partir de esos archivos y de
  `image/distros/*.conf`.
- `release.yml`: con una etiqueta `v*` construye y prueba las 7 variantes, divide los
  archivos de 2 GiB o más en partes de 1900 MiB, genera manifest y notas en español
  (variantes, cambios, cómo verificar y unir partes, código fuente y licencias) y crea
  el Release (pre-release si la etiqueta tiene guion).
- Prueba: `v0.0.1-test` publicó 38 archivos (7 variantes en 2 o 3 partes cada una).
  El núcleo del creador validó el `manifest.json` y un `.bmap` reales (4.824 rangos,
  4,37 GB con datos de 30 GB, suma interna correcta).

**Decisiones**
- Dividir en partes en lugar de otro alojamiento: GitHub Releases no tiene límite de
  tamaño total, solo 2 GiB por archivo; el creador lee las partes en cadena.
- Lista de paquetes con paquete fuente y versión fuente para cumplir con la GPL.

**Pendiente**
- El instalador del creador se agrega al Release en la fase 5.
## Fase 3 — Portabilidad, resistencia y variantes (2026-11-21)

**Qué se hizo**
- Portabilidad: initramfs con `MODULES=most`, entrada de GRUB "Llevix (modo gráficos
  seguros)" con `nomodeset`, sin conexiones de red guardadas.
- Cuidado del disco: journald en RAM, `/tmp` en RAM, `noatime` y zstd, `fstrim.timer`,
  TRIM para SSD/NVMe por USB (solo si el adaptador anuncia UNMAP), sin suspensión USB
  ni apagado del HDD del sistema, planificador de E/S por tipo de disco.
- Resistencia: subvolumen `@snapshots`; antes de cada `apt` se guarda un estado (máximo 5)
  que aparece en GRUB en "Llevix: volver a un estado anterior".
- 7 variantes: Ubuntu, Kubuntu, Xubuntu, Lubuntu (24.04) y Linux Mint 22.3 Cinnamon,
  MATE y Xfce. Matriz en GitHub Actions: las 7 pasan arranque (UEFI+SB, UEFI, BIOS),
  primer arranque y `tests/resistencia-test.sh` (25 comprobaciones, incluido un corte de
  corriente durante una escritura de 8 GB y un `btrfs scrub` sin errores).
- Sin config del creador: GNOME ofrece crear la cuenta; en los demás escritorios se crea
  `llevix`/`llevix` con cambio de contraseña obligatorio (`LLEVIX-LEEME.txt` en la ESP).

**Decisiones**
- Interfaces de red con nombres predecibles de systemd; ninguna config usa un nombre fijo.
- Mint: repositorio `packages.linuxmint.com` (22.3 "zena") con prioridad 700 como Mint;
  llave verificada por SHA256 (el servidor no tiene HTTPS); se usa el llavero de
  `/etc/apt/trusted.gpg.d` (el de `/usr/share/keyrings` es de 2016 y no sirve).
- Mint: se instalan `lightdm` y `slick-greeter` explícitamente (los metapaquetes de
  Cinnamon y MATE no los traen).
- Los estados guardados se arrancan como sistemas completos (su fstab apunta a su propio
  subvolumen); `@home` no se incluye, así que volver atrás no borra archivos.

**Problemas encontrados**
- `findmnt -R` sin `-l` devolvía dibujos de árbol: la limpieza no desmontaba bien.
- Las capturas tomadas tras varios minutos salían negras (pantalla apagada por
  inactividad): ahora se captura al llegar y se comprueba el proceso del saludo.

**Pendiente**
- Prueba humana en 3 PCs reales (ver PENDIENTES.md).
- Firefox (snap) no está en las variantes de Ubuntu; en Mint sí (paquete .deb).
- El saludo de inicio de sesión de Mint muestra el logo de Mint (no se cambia el
  escritorio). Decidir si quitar logos de las distros en imágenes modificadas.
- Probar Secure Boot con firmware que tenga solo el certificado 2011, solo el 2023 y ambos.
## Fase 2 — Primer arranque personalizado (2026-11-21)

**Qué se hizo**
- Formato `llevix-config.json` (docs/llevix-config.md) y `tools/make-config.sh`.
- Servicio `llevix-firstboot`: valida todo antes de tocar nada; amplía LLEVIX-DATOS al
  final del disco (solo el disco de Llevix, solo la partición 1 vacía); aplica nombre del
  equipo, zona horaria, idioma y teclado; crea el usuario con sudo usando el hash
  SHA-512; monta LLEVIX-DATOS en `~/Datos`; borra el config y se desactiva.
  Con errores: deshace, escribe `LLEVIX-ERROR.txt` en la ESP y el sistema sigue arrancando.
- Se quitó el usuario temporal y el inicio automático de la fase 1.
- `tests/lib/qemu.sh`: funciones comunes; el agente de QEMU (`qemu-guest-agent`, que
  solo se activa dentro de una máquina virtual) permite ejecutar comprobaciones dentro de Llevix.
- `tests/firstboot-test.sh`: 24 comprobaciones (config válido en disco de 32 GB,
  persistencia tras apagar y volver a arrancar, config con errores). Todo verde en CI.

**Decisiones**
- exFAT no se puede agrandar: como en el primer arranque LLEVIX-DATOS está vacía, se
  recrea la partición hasta el final del disco y se vuelve a formatear.
- `~/Datos` se monta por UUID (único por disco) con `nofail`: si falta, igual arranca.
- Sin config, se usa la bienvenida de la distribución (GNOME crea la cuenta).
- Paquetes de idioma español incluidos en la imagen para que todo salga en español sin internet.

**Problemas encontrados**
- Hablar con el agente de QEMU abriendo una conexión por comando mezclaba respuestas:
  se usa una sola conexión con `guest-sync-delimited`.

**Pendiente**
- Accesibilidad (`accesibilidad.*`) se valida pero se aplicará en la fase 7g.

## Fase 1 — Primera imagen que arranca (2026-11-21)

**Qué se hizo**
- `image/build.sh <variante>`: imagen GPT de 28 GiB (dispersa) con BIOS boot, ESP,
  sistema btrfs (`@`, `@home`, zstd) y LLEVIX-DATOS (exFAT, número 1, al final).
  debootstrap de noble, `linux-generic`, `linux-firmware`, shim + GRUB firmados
  (modo removable, sin tocar NVRAM) y GRUB BIOS. Escritorio `ubuntu-desktop-minimal`.
- `image/overlay/`: servicio `llevix-estado-arranque` que informa por puerto serie el
  modo de arranque (bios/uefi/uefi-sb) y si el gestor de sesión está activo.
- `tests/qemu-boot-test.sh`: arranca la imagen como memoria USB (xHCI) en los tres
  modos y comprueba el informe; guarda capturas de pantalla.
- `.github/workflows/build.yml`: construye, prueba y sube `llevix-ubuntu-24.04.img.zst`
  (3,6 GB) como artefacto. Resultado: UEFI+SB 2 min, UEFI 65 s, BIOS 35 s (con KVM).

**Decisiones**
- Imagen de 28 GiB en lugar de 32 GB: una memoria "de 32 GB" real tiene 28,6–29,8 GiB.
- Etiqueta exFAT `LLEVIX` (máximo 11 caracteres); la partición GPT se llama `LLEVIX-DATOS`.
- GRUB firmado de Ubuntu busca grub.cfg en EFI/ubuntu, junto a sí mismo o en
  /boot/grub de la ESP: se deja un grub.cfg "puente" en los tres lugares.
- Firefox y Thunderbird (snaps) excluidos por ahora; se agregarán como snaps sembrados.
- Marca: GRUB y PRETTY_NAME dicen "Llevix, basado en Ubuntu 24.04 LTS"; logo de
  plymouth reemplazado. El escritorio (logos de GNOME/Ubuntu en apps) queda como lo
  trae la distro, según la regla "Llevix NO cambia el escritorio".

**Problemas encontrados**
- KVM quedaba solo para root tras instalar paquetes en el chroot: se activa después.
- El informe del puerto serie llegaba pegado a códigos de pantalla del firmware.

**Pendiente**
- Todas las imágenes comparten UUID de btrfs/ESP: dos USB de Llevix conectados a la
  vez podrían confundirse. Evaluar regenerar UUIDs en el creador o en el primer arranque.
- Probar con firmware que tenga solo el certificado 2011, solo el 2023 y ambos (Secure Boot).
- La captura en modo BIOS sale negra aunque el escritorio esté activo (revisar en fase 3).

## Fase 0 — Arranque del proyecto (2026-11-21)

**Qué se hizo**
- Estructura de carpetas, README.md, CONTRIBUTING.md, .gitignore y .gitattributes.
- `tools/check-env.sh`: revisa el entorno en Windows (creador), WSL/Linux (imágenes y
  pruebas) y lo común (git, gh, Node.js). Dentro de WSL ignora los programas de Windows
  que WSL comparte en el PATH (antes daba `npm` por instalado cuando no lo estaba).
- `.github/workflows/lint.yml`: shellcheck en todos los `.sh`.

**Decisiones**
- `.gitattributes` fuerza LF en todo el repositorio (se trabaja desde Windows).
- shellcheck local se ejecuta con Docker (`koalaman/shellcheck`) porque no está instalado.

**Pendiente**
- `check-env.sh` todavía marca faltantes en la PC del dueño (Rust en Windows; paquetes
  de imagen y Node.js en WSL). Instalarlos necesita la contraseña de sudo: ver PENDIENTES.md.
  No bloquea el avance porque la construcción y las pruebas corren en GitHub Actions.
- La WSL del dueño tiene Ubuntu 26.04, no 24.04 (la base de Llevix). Para desarrollar
  sirve igual.
