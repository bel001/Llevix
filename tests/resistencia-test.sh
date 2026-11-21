#!/usr/bin/env bash
# resistencia-test.sh — Pruebas de portabilidad, cuidado del disco y resistencia.
#
# Uso: ./tests/resistencia-test.sh <imagen.img>
#
# 1. Ajustes: journald en RAM, /tmp en RAM, noatime, TRIM, planificador, entrada de
#    gráficos seguros, initramfs genérico y /.snapshots.
# 2. Estados: instalar un paquete con apt guarda un snapshot y lo agrega al menú de GRUB.
# 3. Apagado brusco: se "corta la corriente" (se mata QEMU) mientras se escriben archivos
#    grandes; Llevix debe volver a arrancar y btrfs no debe tener errores.
#
# No necesita root. Trabaja sobre una copia de la imagen.

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"
MODO="${LLEVIX_TEST_MODO:-uefi-sb}"
USUARIO="prueba"

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -eq 1 ]] || { echo "uso: $0 <imagen.img>" >&2; exit 2; }
IMG="$(realpath "$1")"
[[ -f "$IMG" ]] || { echo "no existe la imagen: $IMG" >&2; exit 2; }
for h in mcopy partx openssl; do
    command -v "$h" >/dev/null || { echo "falta $h (paquetes mtools, util-linux, openssl)" >&2; exit 2; }
done
qemu_requisitos

mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d "$DIR_PRUEBAS/trabajo.XXXXXX")"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT

fallos=0
ok()    { printf '  \e[32m[ok]\e[0m    %s\n' "$*"; }
falla() { printf '  \e[31m[falla]\e[0m %s\n' "$*"; fallos=$((fallos + 1)); }
comprobar() {  # comprobar <descripción> <comando sh dentro de Llevix> [segundos]
    if qga_ejecutar "$2" "${3:-120}" > "$TRABAJO/salida.txt" 2>&1; then
        ok "$1"
    else
        falla "$1"
        sed 's/^/          /' "$TRABAJO/salida.txt"
    fi
}

"$DIR_REPO/tools/make-config.sh" --usuario "$USUARIO" --contrasena "clave-de-prueba" \
    > "$TRABAJO/config.json"
preparar_disco "$IMG" "$TRABAJO/disco.img" 32G "$TRABAJO/config.json"

# ---------- 1. Ajustes de portabilidad y cuidado del disco ----------

echo; echo "Arranque 1: ajustes de portabilidad y cuidado del disco"
qemu_iniciar resistencia "$MODO" "$TRABAJO/disco.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    comprobar "el registro del sistema (journald) está en RAM" \
        "test -d /run/log/journal && ! find /var/log/journal -name '*.journal' 2>/dev/null | grep -q ."
    comprobar "/tmp está en RAM" "test \"\$(findmnt -no FSTYPE /tmp)\" = tmpfs"
    comprobar "el sistema se monta con noatime" "findmnt -no OPTIONS / | grep -q noatime"
    comprobar "el sistema usa compresión zstd" "findmnt -no OPTIONS / | grep -q 'compress=zstd'"
    comprobar "TRIM periódico activado (fstrim.timer)" "systemctl is-enabled -q fstrim.timer"
    comprobar "ajustes de energía del disco aplicados" \
        "test \"\$(systemctl show -p Result --value llevix-disco-sistema.service)\" = success"
    comprobar "planificador de E/S ajustado" \
        "d=\$(lsblk -no PKNAME \$(findmnt -no SOURCE / | sed 's/\\[.*//')); grep -Eq '\\[(bfq|mq-deadline|none)\\]' /sys/block/\$d/queue/scheduler"
    comprobar "initramfs con todos los módulos (MODULES=most)" \
        "grep -q '^MODULES=most' /etc/initramfs-tools/conf.d/llevix.conf"
    comprobar "entrada 'modo gráficos seguros' en el menú" \
        "grep -q 'gráficos seguros' /boot/grub/grub.cfg && grep -q nomodeset /boot/grub/grub.cfg"
    comprobar "no hay conexiones de red guardadas atadas a una tarjeta" \
        "! ls /etc/NetworkManager/system-connections/ 2>/dev/null | grep -q ."
    comprobar "/.snapshots está montado" "mountpoint -q /.snapshots"

    # ---------- 2. Estado guardado antes de apt ----------
    echo; echo "Estados: instalar un paquete guarda un estado del sistema"
    comprobar "instalar un paquete local con apt" "set -e
        mkdir -p /tmp/pkg/DEBIAN
        printf 'Package: llevix-prueba\nVersion: 1.0\nArchitecture: all\nMaintainer: Llevix <prueba@llevix.invalid>\nDescription: paquete de prueba\n' > /tmp/pkg/DEBIAN/control
        dpkg-deb --build /tmp/pkg /tmp/llevix-prueba.deb >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/llevix-prueba.deb" 600
    comprobar "se guardó un estado en /.snapshots" "ls /.snapshots | grep -q apt"
    comprobar "el estado tiene su propio fstab" "grep -q 'subvol=@snapshots/' /.snapshots/*apt/etc/fstab"
    comprobar "el estado tiene kernel e initramfs" \
        "test -e /.snapshots/*apt/boot/vmlinuz -a -e /.snapshots/*apt/boot/initrd.img"
    comprobar "el menú de arranque ofrece volver al estado" \
        "grep -q 'volver a un estado anterior' /boot/grub/grub.cfg && grep -q 'rootflags=subvol=@snapshots/' /boot/grub/grub.cfg"

    # ---------- 3. Apagado brusco ----------
    echo; echo "Apagado brusco durante una escritura"
    comprobar "archivo de control antes del corte" \
        "echo antes > /home/$USUARIO/antes.txt && echo antes > /home/$USUARIO/Datos/antes.txt && sync"
    comprobar "empieza a escribir archivos grandes" \
        "setsid sh -c 'dd if=/dev/urandom of=/home/$USUARIO/grande.bin bs=1M count=4000 & dd if=/dev/urandom of=/home/$USUARIO/Datos/grande.bin bs=1M count=4000 &' >/dev/null 2>&1 < /dev/null; sleep 1"
    sleep 10
    qemu_captura "$DIR_PRUEBAS/resistencia-antes-del-corte.png"
    echo "  se corta la corriente (QEMU se detiene de golpe)"
    qemu_matar
else
    falla "el primer arranque no llegó al escritorio"
    tail -n 40 "$QEMU_SERIE" || true
    qemu_matar
fi

echo; echo "Arranque 2: después del corte de corriente"
qemu_iniciar resistencia "$MODO" "$TRABAJO/disco.img" raw
if qemu_esperar_informe "$TIMEOUT" && qga_esperar 120; then
    ok "volvió a arrancar hasta el escritorio"
    comprobar "btrfs sin errores de dispositivo" \
        "btrfs device stats / | awk '{s += \$2} END {exit s != 0}'"
    comprobar "verificación completa de btrfs (scrub) sin errores" "btrfs scrub start -B / >/dev/null" 900
    comprobar "el archivo de antes del corte sigue en la carpeta personal" "grep -q antes /home/$USUARIO/antes.txt"
    comprobar "LLEVIX-DATOS se montó después del corte" "findmnt /home/$USUARIO/Datos >/dev/null"
    comprobar "el archivo de antes del corte sigue en Datos" "grep -q antes /home/$USUARIO/Datos/antes.txt"
else
    falla "después del corte de corriente no volvió a arrancar"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_captura "$DIR_PRUEBAS/resistencia-despues-del-corte.png"
qemu_apagar || true

echo
if (( fallos == 0 )); then
    printf '\e[32mResistencia: todas las comprobaciones pasaron.\e[0m\n'
else
    printf '\e[31mResistencia: %d comprobación(es) fallaron.\e[0m\n' "$fallos"
fi
(( fallos == 0 ))
