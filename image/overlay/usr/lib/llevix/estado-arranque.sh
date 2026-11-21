#!/usr/bin/env bash
# estado-arranque.sh — Escribe en el puerto serie (ttyS0) cómo arrancó el sistema.
# Formato que lee tests/qemu-boot-test.sh:
#   LLEVIX-ARRANQUE modo=<bios|uefi|uefi-sb> gestor=<estado del gestor de sesión>
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

{
    # Salto de línea inicial: el firmware deja códigos de pantalla en la línea actual.
    echo
    echo "LLEVIX-ARRANQUE modo=$modo gestor=$gestor"
    echo "Unidades con fallo:"
    systemctl --failed --no-legend --plain 2>/dev/null || true
    echo "LLEVIX-ARRANQUE-FIN"
} >&3 2>/dev/null || true
