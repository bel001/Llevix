#!/usr/bin/env bash
# verificar-escritorio.sh — Comprueba que un sistema trae lo que cualquier usuario necesita
# desde el primer minuto. Se ejecuta DENTRO del sistema (chroot) al construir una imagen;
# si falta algo, termina con error y la imagen no se publica.
set -euo pipefail

falta=""
instalado() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
alguno() { for p in "$@"; do instalado "$p" && return 0; done; return 1; }

alguno network-manager           || falta="$falta red(network-manager)"
alguno wpasupplicant iwd         || falta="$falta wifi(wpasupplicant)"
alguno network-manager-gnome plasma-nm nm-tray gnome-shell || falta="$falta icono-de-red"
alguno pipewire-pulse pulseaudio || falta="$falta sonido"
alguno wireplumber pulseaudio    || falta="$falta sonido(sesion)"
navegador=""
for b in /usr/lib/firefox/firefox /usr/lib/firefox-esr/firefox-esr /usr/bin/chromium /usr/bin/brave-browser; do
    [[ -x "$b" ]] && navegador="$b" && break
done
[[ -n "$navegador" ]]            || falta="$falta navegador"
test -e /etc/alternatives/x-terminal-emulator || falta="$falta terminal"
alguno nautilus dolphin thunar pcmanfm-qt nemo caja pantheon-files || falta="$falta archivos"

if [[ -n "$falta" ]]; then
    echo "Faltan componentes básicos:$falta" >&2
    exit 1
fi
echo "Escritorio completo: red, wifi, sonido, navegador ($navegador), terminal y archivos."
