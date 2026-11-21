# Pendientes para el dueño del proyecto

Claude Code escribe aquí lo que necesita de ti. Resuélvelo, marca la casilla y
vuelve a pegar el prompt de AUTOPILOTO.md para que continúe.

## Ahora
- [ ] Instalar lo que falta en tu PC (no bloquea: las pruebas corren en GitHub Actions).
  1. En PowerShell, para el creador: `winget install --id Rustlang.Rustup -e`
  2. En PowerShell, para WSL (te pedirá la contraseña de Ubuntu):
     `wsl -d Ubuntu -- bash -c "sudo apt update && sudo apt install -y debootstrap parted dosfstools exfatprogs btrfs-progs zstd bmap-tools jq shellcheck gh qemu-system-x86 qemu-utils ovmf seabios nodejs npm"`
  3. Comprueba con `./tools/check-env.sh` en Git Bash y dentro de WSL.

## Decisiones abiertas
- [ ] Licencia: GPL-3.0 (recomendada) o MIT — decidir antes de la beta
- [ ] Confirmar que "Llevix" está libre como marca, dominio y en redes
- [ ] Firma del instalador de Windows: SignPath Foundation, certificado OV o sin firma
