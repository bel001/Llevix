#!/usr/bin/env bash
# disco-sistema.sh — Ajustes para el disco desde el que arrancó Llevix:
# - que el puerto USB no lo suspenda por ahorro de energía;
# - si es un disco giratorio (HDD), que no se apague ni estacione el cabezal a cada rato.
# Lo ejecuta llevix-disco-sistema.service en cada arranque. Nunca escribe datos en el disco.
set -euo pipefail

raiz="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
disco="$(lsblk -no PKNAME "$raiz" | head -n1)"
[[ -n "$disco" && -e "/sys/block/$disco" ]] || exit 0

# Sube por el árbol del dispositivo y desactiva la autosuspensión de USB.
ruta="$(readlink -f "/sys/block/$disco/device")"
while [[ "$ruta" != "/" && "$ruta" != "/sys" ]]; do
    if [[ -f "$ruta/power/control" && -f "$ruta/idVendor" ]]; then
        echo on > "$ruta/power/control" 2>/dev/null || true
    fi
    ruta="$(dirname "$ruta")"
done

if [[ "$(cat "/sys/block/$disco/queue/rotational" 2>/dev/null)" == "1" ]] && command -v hdparm >/dev/null; then
    # -S 0: sin apagado por inactividad. -B 254: máximo rendimiento sin estacionar.
    # Muchas memorias USB no entienden estas órdenes: se ignoran los errores.
    hdparm -S 0 -B 254 "/dev/$disco" >/dev/null 2>&1 || true
fi
