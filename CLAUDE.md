# Llevix

Llevix crea memorias USB y discos externos (HDD, SSD, NVMe en caja USB) con Linux
portátil y persistente que arrancan en cualquier PC x86_64. El usuario elige la
distribución, escribe usuario y contraseña, y el disco queda listo. Sus archivos se
conservan entre computadoras y la partición de datos también se abre desde el celular.

Documentos de referencia, si existen en el repositorio (leerlos cuando haga falta contexto):
- docs/definicion-producto.md: qué es Llevix, público, alcance de la v1, riesgos.
- docs/plan-desarrollo.md: fases de desarrollo con sus prompts y criterios de prueba.

Idioma del proyecto: español (código comentado, mensajes al usuario, documentación).

## Arquitectura
- image/: construye una imagen .img por cada variante de distro con debootstrap.
- creator/: app de escritorio para Windows (Tauri 2 + Svelte) que descarga la
  imagen, verifica su SHA256, la escribe al disco y deja llevix-config.json en la ESP.
- firstboot: servicio systemd que en el primer arranque lee llevix-config.json, crea el
  usuario, aplica idioma y zona horaria, amplía la partición de datos y borra el archivo.
- Llevix NO instala Linux desde Windows: escribe una imagen ya construida y probada.
  Con "Trae tu ISO" (fase 8) la instalación de la ISO ocurre en Linux, en el propio disco.

## Distribuciones (las elige el usuario)
- Llevix NO cambia el escritorio: cada variante se entrega como la distro la trae.
- v1: Ubuntu 24.04 LTS (Ubuntu, Kubuntu, Xubuntu, Lubuntu), Linux Mint 22 (Cinnamon, MATE,
  Xfce), Debian 13 (GNOME, KDE Plasma, Xfce) y Zorin OS 18 Core (construida desde su ISO
  oficial con image/desde-iso.sh). Cada variante es un archivo en image/distros/.
- El creador marca como "ligeras" las variantes para PCs con poca RAM (Xubuntu,
  Lubuntu, Mint Xfce, Mint MATE).
- Lo que Llevix sí agrega a todas: capa de portabilidad, primer arranque y ajustes
  para escribir poco en el disco.

## Tecnologías
- Imágenes: bash + debootstrap; btrfs con compresión zstd (menos lectura del USB).
- Primer arranque: bash + systemd.
- Creador: Tauri 2 (Rust) + Svelte. Instalador pequeño, interfaz liviana.
- Escritura al disco: en Rust, solo los bloques con datos según el mapa bmap,
  descomprimiendo zstd mientras escribe (sin archivos temporales grandes).
- Publicación: imágenes .img.zst + .bmap + SHA256 + manifest.json en GitHub Releases.
- Pruebas: QEMU + OVMF (UEFI, Secure Boot) y SeaBIOS.
- CI: GitHub Actions. Web y documentación: Astro en GitHub Pages.

## Particiones (GPT)
1. LLEVIX-DATOS  exFAT  resto del disco (número 1 en la tabla para que Windows y
   Android la vean, pero ubicada físicamente al FINAL del disco para poder ampliarla)
2. BIOS boot     1 MB
3. ESP           FAT32  512 MB
4. Sistema       btrfs  ~25 GB, subvolúmenes @ y @home, snapshots

## Reglas
- Debe arrancar en UEFI con Secure Boot (shim + grub firmados) y en BIOS antiguo.
- Secure Boot: el certificado Microsoft UEFI CA 2011 expiró en junio de 2026. Usar un shim
  firmado con 2011 y 2023 cuando exista, y probar en firmware con solo 2011, solo 2023 y ambos.
- Nunca pedir al usuario que desactive Secure Boot (puede disparar la recuperación de
  BitLocker en su Windows). Indicar siempre el menú de arranque de una sola vez (F12, F9, Esc).
- Marcas: no distribuir logos ni el nombre "Ubuntu" o "Linux Mint" como marca del producto
  en imágenes modificadas. Presentarlo como "Llevix, basado en Ubuntu".
- Nada atado al hardware: sin xorg.conf fijo, sin drivers propietarios en la imagen.
- Minimizar escrituras al disco: journald en memoria, noatime, /tmp en RAM.
- Soportar cualquier disco conectado por USB: TRIM en SSD/NVMe, sin asumir tamaño fijo.
- Nunca guardar contraseñas en texto plano: solo hash SHA-512.
- El creador nunca debe mostrar ni escribir discos internos o el disco del sistema.
  Si el disco elegido tiene datos, mostrar su contenido y pedir doble confirmación.
- Todo cambio en image/ debe pasar tests/qemu-boot-test.sh en UEFI y BIOS.
- Scripts en bash con `set -euo pipefail`.

## Licencia
- MIT (archivo LICENSE), decidido por el dueño el 2026-11-22. Cubre el código de Llevix
  (scripts, creador, pruebas). Cada imagen incluye software de las distros con sus propias
  licencias (GPL y otras): por eso el Release publica la lista de paquetes y dónde está su
  código fuente.
- No copiar código GPL dentro de este repositorio (haría GPL a todo el proyecto). Usar
  dependencias con licencias compatibles con MIT (MIT, BSD, Apache-2.0, ISC, Zlib…).

## Forma de trabajo
- Modo principal: piloto automático. Seguir las reglas de AUTOPILOTO.md.
- Prompts de cada fase: prompts/fase-N-*.md. Planes: docs/planes/. Historial: docs/BITACORA.md.
- Lo que necesite al dueño (decisiones, cuentas, pruebas físicas): escribirlo en PENDIENTES.md.
- Lo que necesite sudo, loop devices o QEMU: probarlo en GitHub Actions
  (git push → gh run watch → gh run view --log-failed → corregir).
- Explicar los cambios en español sencillo; el dueño del proyecto está aprendiendo.
- Una rama de Git por fase y commits pequeños.

## Seguridad de discos (nunca romper)
- Jamás escribir en /dev/sd*, /dev/nvme*, /dev/mmcblk* ni \\.\PhysicalDrive* desde
  scripts de construcción o pruebas. Solo archivos .img y loop devices.
- No usar dd contra dispositivos. Para imágenes vacías: truncate o fallocate.
- El único código que escribe en discos reales es el creador (fase 5), y sus
  pruebas usan discos simulados.

## Estado actual
- Fase 0: completa (lint verde en GitHub). Pendiente humano: instalar paquetes locales (PENDIENTES.md).
- Fase 1: completa (build verde: UEFI+SB, UEFI y BIOS llegan al escritorio en QEMU).
- Fase 2: completa (primer arranque: usuario, datos, persistencia y errores verdes en CI).
- Fase 3: completa en lo automático (7 variantes verdes: arranque, primer arranque y
  resistencia). Pendiente humano: probar en 3 PCs reales (PENDIENTES.md).
- Fase 4: completa (release.yml; Release de prueba v0.0.1-test con 7 variantes y manifest.json).
- Fase 5: completa en lo automático (creador: pruebas en Linux y Windows, instalador
  .exe/.msi, prueba e2e con QEMU). Pendiente humano: crear un USB real (PENDIENTES.md).
- Fase 6: preparada (report.sh, plantillas de issues, docs/BETA.md, README). El piloto
  automático se detuvo: siguen tareas humanas de la beta (PENDIENTES.md).
- Beta: arreglado "escritorio completo" (red, sonido, Firefox y repositorios de Mint;
  Mint con la lista de su ISO oficial). Versión de prueba v0.0.4-test.
- Decidido A + B: catálogo más grande y "Trae tu ISO" (docs/planes/catalogo-e-iso-propia.md).
- Fase 8: completa en lo automático ("Trae tu ISO": Mint, Kubuntu y Ubuntu reales verdes en
  CI con el núcleo del creador). Pendiente humano: probarlo en un USB real (PENDIENTES.md).
- Fase 9: completa en lo automático (11 variantes verdes: + Debian 13 GNOME/KDE/Xfce y
  Zorin OS 18 desde su ISO oficial; creador con interfaz nueva). Licencia MIT.
- Siguiente paso: pruebas humanas de la beta (PENDIENTES.md) y, con ellas, v0.1.0-beta.1.
  Después: elementary OS (fuente estable), Fedora y Secure Boot con el certificado 2023.
- Herramientas locales: shellcheck con Docker
  (`MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W)":/mnt -w /mnt koalaman/shellcheck:stable -x <archivos>`).

## Comandos
- Verificar entorno: ./tools/check-env.sh
- Construir: sudo ./image/build.sh ubuntu-24.04
- Probar: ./tests/qemu-boot-test.sh out/llevix-ubuntu-24.04.img
