#!/usr/bin/env bash
# qemu-boot-test.sh — Arranca una imagen de Llevix en QEMU y comprueba que llega al escritorio.
#
# Uso:   ./tests/qemu-boot-test.sh <imagen.img> [modo...]
# Modos: uefi-sb (UEFI + Secure Boot), uefi (UEFI sin Secure Boot), bios (SeaBIOS).
#        Sin modos, prueba los tres.
#
# Variables opcionales:
#   LLEVIX_TEST_DIR       carpeta para registros y capturas (por defecto: out/pruebas)
#   LLEVIX_TEST_TIMEOUT   segundos máximos por arranque (por defecto: 900)
#   LLEVIX_TEST_BUS       usb (por defecto, como una memoria real) o virtio
#   LLEVIX_TEST_MEM       memoria en MiB (por defecto: 4096)
#
# No necesita root. Nunca modifica la imagen: escribe en una capa qcow2 aparte.

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -ge 1 ]] || { echo "uso: $0 <imagen.img> [uefi-sb] [uefi] [bios]" >&2; exit 2; }
IMG="$(realpath "$1")"
shift
[[ -f "$IMG" ]] || { echo "no existe la imagen: $IMG" >&2; exit 2; }
MODOS=("$@")
(( ${#MODOS[@]} > 0 )) || MODOS=(uefi-sb uefi bios)

qemu_requisitos
mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d)"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT

# probar_modo <modo> → 0 si arrancó bien.
probar_modo() {
    local modo="$1" capa="$TRABAJO/$1.qcow2" motivo resultado=1 inicio=$SECONDS
    qemu-img create -q -f qcow2 -b "$IMG" -F raw "$capa"
    qemu_iniciar "$modo" "$modo" "$capa" qcow2

    if qemu_esperar_informe "$TIMEOUT"; then
        if [[ "$INFORME_MODO" != "$modo" ]]; then
            motivo="arrancó en modo '$INFORME_MODO' y se esperaba '$modo'"
        elif [[ "$INFORME_GESTOR" != "active" ]]; then
            motivo="el gestor de sesión no está activo ('$INFORME_GESTOR')"
        else
            resultado=0
            motivo="llegó al escritorio en $((SECONDS - inicio)) s (primer arranque: ${INFORME_PRIMER_ARRANQUE:-?})"
            sleep 15   # para que la captura muestre el escritorio ya dibujado
        fi
    else
        motivo="no llegó al escritorio"
    fi

    qemu_captura "$DIR_PRUEBAS/$modo-pantalla.png"
    qemu_matar

    if (( resultado == 0 )); then
        printf '\e[32mOK\e[0m    %s: %s\n' "$modo" "$motivo"
    else
        printf '\e[31mFALLA\e[0m %s: %s\n' "$modo" "$motivo"
        echo "Últimas líneas del puerto serie:"
        tail -n 40 "$QEMU_SERIE" 2>/dev/null || echo "(vacío)"
    fi
    sed -n '/Unidades con fallo/,/LLEVIX-ARRANQUE-FIN/p' "$QEMU_SERIE" 2>/dev/null || true
    rm -f "$capa"
    return "$resultado"
}

fallos=0
declare -A RESUMEN=()
for modo in "${MODOS[@]}"; do
    if probar_modo "$modo"; then
        RESUMEN[$modo]="OK"
    else
        RESUMEN[$modo]="FALLA"
        fallos=$((fallos + 1))
    fi
done

printf '\n\e[1mResumen\e[0m (registros y capturas en %s)\n' "$DIR_PRUEBAS"
for modo in "${MODOS[@]}"; do
    printf '  %-8s %s\n' "$modo" "${RESUMEN[$modo]}"
done
(( fallos == 0 ))
