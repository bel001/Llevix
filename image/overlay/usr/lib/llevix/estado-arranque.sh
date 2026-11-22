#!/usr/bin/env bash
# estado-arranque.sh — Escribe en el puerto serie (ttyS0) cómo arrancó el sistema.
# Formato que lee tests/qemu-boot-test.sh:
#   LLEVIX-ARRANQUE modo=<bios|uefi|uefi-sb> gestor=<estado del gestor de sesión>
#   LLEVIX-PRIMER-ARRANQUE resultado=<ok|error|sin-config|pendiente>
#   LLEVIX-INFO clave=valor          (sistema, usuarios, red, sonido, navegador, datos)
#   ...unidades que fallaron...
#   LLEVIX-ARRANQUE-FIN
set -euo pipefail

PUERTO=/dev/ttyS0

# Sin puerto serie usable (lo normal en una PC real) no se hace nada.
exec 3>"$PUERTO" 2>/dev/null || exit 0

modo="bios"
if [[ -d /sys/firmware/efi ]]; then
    modo="uefi"
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "$f" ]] || continue
        # Los 4 primeros bytes son atributos; el quinto vale 1 si Secure Boot está activo.
        if [[ "$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')" == "1" ]]; then
            modo="uefi-sb"
        fi
    done
fi

gestor="$(systemctl is-active display-manager.service 2>/dev/null || true)"

# Resultado de llevix-firstboot: ok, error, sin-config o pendiente.
primer_arranque="$(cut -d: -f1 /var/lib/llevix/firstboot-resultado 2>/dev/null || echo pendiente)"

# Datos para las pruebas que no pueden entrar al sistema (por ejemplo, una distro
# instalada desde una ISO, sin agente de QEMU).
# shellcheck source=/dev/null
sistema="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-desconocido}")"
usuarios="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' | paste -sd, -)"
red="sin-networkmanager"
if command -v nmcli >/dev/null; then
    for _ in $(seq 30); do
        red="$(nmcli -t -f STATE general 2>/dev/null || echo error)"
        [[ "$red" == connected* ]] && break
        sleep 2
    done
fi
sonido="no"
grep -q '\[' /proc/asound/cards 2>/dev/null && sonido="si"
navegador="no"
for b in firefox /usr/lib/firefox/firefox chromium chromium-browser google-chrome brave-browser; do
    command -v "$b" >/dev/null && { navegador="$b"; break; }
done
datos="$(findmnt -rno TARGET -S LABEL=LLEVIX 2>/dev/null | head -n1)"

{
    # Salto de línea inicial: el firmware deja códigos de pantalla en la línea actual.
    echo
    echo "LLEVIX-ARRANQUE modo=$modo gestor=$gestor"
    echo "LLEVIX-PRIMER-ARRANQUE resultado=$primer_arranque"
    echo "LLEVIX-INFO sistema=$sistema"
    echo "LLEVIX-INFO usuarios=$usuarios"
    echo "LLEVIX-INFO red=$red"
    echo "LLEVIX-INFO sonido=$sonido"
    echo "LLEVIX-INFO navegador=$navegador"
    echo "LLEVIX-INFO datos=${datos:-ninguno}"
    echo "Unidades con fallo:"
    systemctl --failed --no-legend --plain 2>/dev/null || true
    # Si el gestor de sesión no arrancó, detalles para diagnosticar.
    if [[ "$gestor" != "active" ]]; then
        echo "Gestor de sesión configurado: $(cat /etc/X11/default-display-manager 2>/dev/null || echo ninguno)"
        systemctl status display-manager.service --no-pager -n 15 2>&1 || true
        for u in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do
            journalctl -b -u "$u" --no-pager -n 15 2>&1 || true
        done
    fi
    echo "LLEVIX-ARRANQUE-FIN"
} >&3 2>/dev/null || true
