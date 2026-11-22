# Pendientes para el dueño del proyecto

Claude Code escribe aquí lo que necesita de ti. Resuélvelo, marca la casilla y
vuelve a pegar el prompt de AUTOPILOTO.md para que continúe.

## Ahora
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

## Decisiones abiertas
- [ ] Licencia: GPL-3.0 (recomendada) o MIT — decidir antes de la beta
- [ ] Confirmar que "Llevix" está libre como marca, dominio y en redes
- [ ] Firma del instalador de Windows: SignPath Foundation, certificado OV o sin firma
- [ ] Logos de las distros: hoy la pantalla de inicio de sesión y el fondo muestran los
      logos de Ubuntu/Kubuntu/Mint tal como los trae cada distro (regla "Llevix no cambia el
      escritorio"). La regla de marcas pide no usarlos como marca del producto. ¿Se quitan
      (fondo y logo neutros de Llevix) o se dejan? Llevix ya cambia GRUB, el nombre del
      sistema y la pantalla de arranque.
- [ ] Firefox en las variantes de Ubuntu: Ubuntu lo trae como snap y no se puede instalar
      dentro de la imagen. Opciones: (a) sembrarlo como snap para que se instale solo en el
      primer arranque con internet, (b) usar el .deb del PPA de Mozilla, (c) dejarlo sin navegador.
