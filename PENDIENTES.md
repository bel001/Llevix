# Pendientes para el dueño del proyecto

Claude Code escribe aquí lo que necesita de ti. Resuélvelo, marca la casilla y
vuelve a pegar el prompt de AUTOPILOTO.md para que continúe.

## Ahora
- [ ] **Revisar la memoria USB de Temu** (Zorin se quedaba cargando).
  1. Descarga **ValiDrive** (grc.com/validrive.htm) o **H2testw** y prueba la memoria
     (borra lo que tenga). Si dice que la capacidad real es menor, la memoria es falsa.
  2. Mide la velocidad con **CrystalDiskMark**: si la escritura **RND4K** da menos de
     1 MB/s, Linux será muy lento en ella (con cualquier distro, no solo con Llevix).
  3. Vuelve a probar Llevix en una memoria **USB 3 de marca** (Kingston, SanDisk, Samsung)
     o en un **SSD externo**. Anota el resultado en `tests/hardware-matrix.md`.

- [ ] Instalar lo que falta en tu PC (no bloquea: las pruebas corren en GitHub Actions).
  1. En PowerShell, para el creador: `winget install --id Rustlang.Rustup -e`
  2. En PowerShell, para WSL (te pedirá la contraseña de Ubuntu):
     `wsl -d Ubuntu -- bash -c "sudo apt update && sudo apt install -y debootstrap parted dosfstools exfatprogs btrfs-progs zstd bmap-tools jq shellcheck gh qemu-system-x86 qemu-utils ovmf seabios nodejs npm"`
  3. Comprueba con `./tools/check-env.sh` en Git Bash y dentro de WSL.

- [ ] **Probar Llevix en al menos 3 PCs reales** (fase 3; no bloquea las fases 4 y 5).
  1. Entra a https://github.com/bel001/Llevix/actions/workflows/build.yml, abre la última
     ejecución verde y descarga el artefacto `llevix-xubuntu-24.04.img.zst` (u otra variante).
  2. Descomprímelo con 7-Zip (queda `llevix-xubuntu-24.04.img`, 28 GB, casi todo vacío).
  3. Escríbelo con Rufus en **modo DD** en una memoria de 32 GB o más **sin datos importantes**.
  4. Arranca con el menú de arranque de una sola vez (F12, F9, Esc…). **No desactives Secure Boot.**
  5. Sin config del creador: en Ubuntu GNOME te pide crear la cuenta; en las demás variantes
     entra con usuario `llevix` y contraseña `llevix` (te pide cambiarla).
  6. Anota cada PC en `tests/hardware-matrix.md`.

- [ ] **Probar el creador en una PC con Windows** (fase 5).
  1. **Primero desconecta cualquier disco externo con datos importantes.**
  2. Descarga el instalador `Llevix-Creador-…-setup.exe` del último Release (o el artefacto
     `creador-llevix-windows` del workflow "creador").
  3. Instálalo. Windows mostrará "Windows protegió tu PC" porque el instalador no está
     firmado: "Más información" → "Ejecutar de todas formas".
  4. Crea un USB (32 GB o más) y comprueba que arranca y que tu usuario y contraseña funcionan.
  5. Anota el resultado en `tests/hardware-matrix.md`.

## Beta (fase 6) — tareas humanas
El piloto automático se detuvo aquí: lo que sigue necesita personas y PCs reales.
- [ ] Probar en **10 PCs distintas** (Intel, AMD, NVIDIA, una vieja con BIOS) y llenar
      `tests/hardware-matrix.md`. Si algo falla: dentro de Llevix, `sudo /usr/lib/llevix/report.sh`
      y abrir un issue con la plantilla que corresponda.
- [ ] Probar la partición de datos en **2 celulares Android** con USB-C (anotar en la matriz).
- [ ] Grabar 2 GIFs para el README: el asistente del creador y el arranque hasta el
      escritorio. Guardarlos en `docs/img/creador.gif` y `docs/img/arranque.gif` (los
      lugares están marcados en el README con `<!-- GIF -->`).
- [ ] Conseguir **20 o más testers** (grupos de Linux en español: Telegram, Discord,
      r/linuxesp). Pasarles `docs/BETA.md`.
- [ ] Publicar la primera versión beta: crear la etiqueta `v0.1.0-beta.1`
      (`git tag -a v0.1.0-beta.1 -m "Beta 1" && git push origin v0.1.0-beta.1`).
      El Release se arma solo.
- [ ] Borrar los Releases de prueba `v0.0.1-test` y `v0.0.2-test` cuando ya no sirvan.
- [ ] Por cada issue, decirle a Claude Code: "revisa el issue #N y corrígelo".

- [ ] **Volver a crear tu USB** con la versión v0.0.4-test (la anterior no tenía red,
      sonido ni navegador en Mint) y probar en las otras PCs: WiFi, sonido, Firefox y el
      Gestor de actualizaciones.

- [ ] **Probar "Usar mi propia ISO"** con la versión v0.0.5-test: en el creador, paso 1,
      "Usar mi propia ISO", elige una ISO de Ubuntu, Linux Mint, Zorin o elementary (máximo
      8 GB). El primer arranque tarda 5 a 15 minutos instalando y se reinicia solo.

## Decisiones abiertas
- [x] Licencia: MIT (decidido el 2026-11-22; archivo LICENSE)
- [ ] Confirmar que "Llevix" está libre como marca, dominio y en redes
- [ ] Código fuente (GPL): cada versión ya guarda el código de sus paquetes y hay una
      oferta escrita por 3 años (docs/CODIGO-FUENTE.md). Tu parte: si alguien abre un issue
      pidiendo el código, contestar con el enlace al Release. Decidir qué hacer con las
      versiones de prueba viejas (v0.0.1 a v0.0.6-test): borrarlas de Releases (si nadie
      más las descargó) o guardarles el código con Actions → fuentes → Run workflow.
- [ ] Zorin OS: leer su política de marcas (https://zorin.com) antes de la beta pública;
      si no permite redistribuir versiones modificadas con su nombre, quitarlo del catálogo.
- [ ] Firma del instalador de Windows: SignPath Foundation, certificado OV o sin firma
- [ ] Logos de las distros: hoy la pantalla de inicio de sesión y el fondo muestran los
      logos de Ubuntu/Kubuntu/Mint tal como los trae cada distro (regla "Llevix no cambia el
      escritorio"). La regla de marcas pide no usarlos como marca del producto. ¿Se quitan
      (fondo y logo neutros de Llevix) o se dejan? Llevix ya cambia GRUB, el nombre del
      sistema y la pantalla de arranque.
- [x] Firefox: resuelto (repositorio oficial de Mozilla en Ubuntu, el de Mint en Mint).
