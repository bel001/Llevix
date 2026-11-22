#!/usr/bin/env bash
# report.sh — Reporte de diagnóstico de Llevix para adjuntar a un issue de GitHub.
#
# Se ejecuta DENTRO de Llevix:   bash report.sh     (mejor con sudo para más detalle)
# Guarda un .txt en ~/Datos (o en la carpeta personal) y muestra dónde quedó.
#
# Recopila: marca y modelo de la PC, CPU, GPU, memoria, modo de arranque (UEFI/BIOS),
# Secure Boot, versión de Llevix, discos (sin números de serie), red (solo chips y
# controladores) y los errores del arranque actual.
#
# Privacidad: quita tu nombre de usuario, el nombre del equipo, direcciones MAC e IP,
# números de serie, UUID y nombres de redes WiFi. Revisa el archivo antes de subirlo.

set -euo pipefail

usuario_real="${SUDO_USER:-$USER}"
casa="$(getent passwd "$usuario_real" | cut -d: -f6)"
destino_dir="$casa/Datos"
[[ -d "$destino_dir" && -w "$destino_dir" ]] || destino_dir="$casa"
archivo="$destino_dir/llevix-reporte-$(date +%Y%m%d-%H%M%S).txt"
equipo="$(hostname)"

seccion() { printf '\n===== %s =====\n' "$1"; }
leer() { cat "$1" 2>/dev/null || echo "(no disponible)"; }
ejecutar() { "$@" 2>&1 || echo "(no se pudo ejecutar: $*)"; }

# Quita datos personales de un texto.
anonimizar() {
    local u_re e_re
    u_re="$(printf '%s' "$usuario_real" | sed 's/[]\/$*.^[]/\&/g')"
    e_re="$(printf '%s' "$equipo" | sed 's/[]\/$*.^[]/\&/g')"
    sed -E \
        -e "s/\b$u_re\b/<usuario>/g" \
        -e "s/\b$e_re\b/<equipo>/g" \
        -e 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/<mac>/g' \
        -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g' \
        -e 's/\b[0-9a-fA-F]{4}(:[0-9a-fA-F]{0,4}){3,7}\b/<ipv6>/g' \
        -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
        -e 's/(SSID|ssid)[=: ]+[^ ]+/\1=<red>/g' \
        -e 's/([Ss]erial( [Nn]umber)?|SerialNumber|iSerial)([=: ]+)[^ ]+/\1\3<serie>/g'
}

{
    echo "Reporte de Llevix — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Revisa este archivo antes de compartirlo. No debería tener datos personales."

    seccion "Llevix"
    leer /etc/llevix/version
    echo "Primer arranque: $(leer /var/lib/llevix/firstboot-resultado)"
    echo "Kernel: $(uname -r)"
    echo "Línea de arranque: $(leer /proc/cmdline)"

    seccion "PC"
    for c in sys_vendor product_name product_version board_vendor board_name bios_vendor bios_version bios_date; do
        printf '%-16s %s\n' "$c:" "$(leer "/sys/class/dmi/id/$c")"
    done
    if [[ -d /sys/firmware/efi ]]; then
        echo "Arranque: UEFI"
        sb="desconocido"
        for f in /sys/firmware/efi/efivars/SecureBoot-*; do
            [[ -r "$f" ]] && sb="$([[ "$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')" == 1 ]] && echo activado || echo desactivado)"
        done
        echo "Secure Boot: $sb"
    else
        echo "Arranque: BIOS (legacy)"
    fi

    seccion "CPU y memoria"
    ejecutar lscpu | grep -E '^(Model name|Architecture|CPU\(s\)|Thread|Core|Vendor ID)' || true
    ejecutar free -h

    seccion "Gráficos"
    ejecutar lspci -nnk | grep -A3 -E 'VGA|3D|Display' || true
    echo "Sesión: ${XDG_SESSION_TYPE:-desconocida}  Escritorio: ${XDG_CURRENT_DESKTOP:-desconocido}"

    seccion "Red (chips y controladores)"
    ejecutar lspci -nnk | grep -A3 -E 'Network|Ethernet' || true
    ejecutar lsusb
    ejecutar rfkill list

    seccion "Discos"
    ejecutar lsblk -o NAME,SIZE,TYPE,TRAN,ROTA,FSTYPE,LABEL,MOUNTPOINTS
    ejecutar findmnt -no SOURCE,FSTYPE,OPTIONS /

    seccion "Servicios con fallo"
    ejecutar systemctl --failed --no-pager

    seccion "Errores del arranque actual"
    ejecutar journalctl -b -p err --no-pager -n 200

    seccion "Avisos del kernel"
    ejecutar dmesg --level=err,warn | tail -n 150
} 2>&1 | anonimizar > "$archivo"

if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER": "$archivo" 2>/dev/null || true
fi
echo "Reporte guardado en: $archivo"
echo "Revísalo y adjúntalo a un issue en https://github.com/bel001/Llevix/issues"
