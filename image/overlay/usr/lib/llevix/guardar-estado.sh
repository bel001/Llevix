#!/usr/bin/env bash
# guardar-estado.sh [motivo] — Guarda un "estado" del sistema: un snapshot btrfs del
# subvolumen @ en /.snapshots/<fecha>-<motivo>, y lo agrega al menú de arranque.
#
# - Solo guarda el sistema (@). La carpeta personal (@home) y LLEVIX-DATOS no se tocan,
#   así que volver a un estado anterior no borra tus archivos.
# - Conserva los 5 estados más recientes.
# - Si ya se guardó uno hace menos de 2 minutos, no hace nada (apt puede llamar varias veces).
set -euo pipefail

motivo="${1:-manual}"
[[ "$motivo" =~ ^[a-z0-9-]+$ ]] || motivo="manual"
DIR=/.snapshots
MAXIMO=5

[[ $EUID -eq 0 ]] || { echo "guardar-estado: necesita root" >&2; exit 1; }
[[ "$(findmnt -no FSTYPE /)" == "btrfs" ]] || exit 0
mountpoint -q "$DIR" || { echo "guardar-estado: $DIR no está montado" >&2; exit 0; }

# ¿Hay uno muy reciente?
ultimo="$(find "$DIR" -mindepth 1 -maxdepth 1 -type d -newermt '-2 minutes' | head -n1)"
[[ -z "$ultimo" ]] || exit 0

nombre="$(date +%Y%m%d-%H%M%S)-$motivo"
btrfs -q subvolume snapshot / "$DIR/$nombre"

# El snapshot se arranca como un sistema completo: su fstab debe montar su propio
# subvolumen como raíz, no @.
sed -i "s#subvol=@,#subvol=@snapshots/$nombre,#" "$DIR/$nombre/etc/fstab"
# Que el estado guardado no vuelva a guardar estados ni ejecute el primer arranque.
rm -f "$DIR/$nombre/etc/apt/apt.conf.d/80llevix-estado"

# Borra los más viejos.
mapfile -t estados < <(find "$DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
for viejo in "${estados[@]:$MAXIMO}"; do
    btrfs -q subvolume delete "$DIR/$viejo" || true
done

if command -v update-grub >/dev/null; then
    update-grub >/dev/null 2>&1 || echo "guardar-estado: no se pudo actualizar el menú de arranque" >&2
fi
echo "Llevix: estado del sistema guardado ($nombre)"
