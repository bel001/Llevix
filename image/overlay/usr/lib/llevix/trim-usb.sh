#!/usr/bin/env bash
# trim-usb.sh <scsi_disk> — Activa TRIM (provisioning_mode=unmap) en un disco USB que
# anuncia soportarlo. Lo llama la regla udev 61-llevix-trim-usb.rules.
set -euo pipefail

disco_scsi="${1:?}"
modo="/sys/class/scsi_disk/$disco_scsi/provisioning_mode"
[[ -w "$modo" ]] || exit 0
[[ "$(cat "$modo")" == "full" ]] || exit 0   # ya tiene un modo de TRIM

bloque=""
for b in "/sys/class/scsi_disk/$disco_scsi/device/block/"*; do bloque="$(basename "$b")"; break; done
[[ -n "$bloque" && -b "/dev/$bloque" ]] || exit 0
command -v sg_vpd >/dev/null || exit 0

# Página VPD "Logical Block Provisioning": LBPU=1 significa que admite UNMAP.
if sg_vpd -p lbpv "/dev/$bloque" 2>/dev/null | grep -q "Unmap command supported (LBPU): 1"; then
    echo unmap > "$modo"
fi
