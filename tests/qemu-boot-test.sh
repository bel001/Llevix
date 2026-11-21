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

# Los argumentos de QEMU llevan comas a propósito (por ejemplo q35,smm=on).
# shellcheck disable=SC2054

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-900}"
BUS="${LLEVIX_TEST_BUS:-usb}"
MEM="${LLEVIX_TEST_MEM:-4096}"

error() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 2; }

[[ $# -ge 1 ]] || error "uso: $0 <imagen.img> [uefi-sb] [uefi] [bios]"
IMG="$(realpath "$1")"
shift
[[ -f "$IMG" ]] || error "no existe la imagen: $IMG"
MODOS=("$@")
(( ${#MODOS[@]} > 0 )) || MODOS=(uefi-sb uefi bios)

for h in qemu-system-x86_64 qemu-img socat; do
    command -v "$h" >/dev/null || error "falta $h (ejecuta ./tools/check-env.sh)"
done

# Busca el primer archivo que exista de una lista.
primero_que_exista() {
    local f
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}

OVMF_CODE_SB="$(primero_que_exista /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd)" \
    || error "falta OVMF con Secure Boot (paquete ovmf)"
OVMF_VARS_MS="$(primero_que_exista /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd)" \
    || error "faltan las variables OVMF con claves de Microsoft (paquete ovmf)"
OVMF_CODE="$(primero_que_exista /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd)" \
    || error "falta OVMF (paquete ovmf)"
OVMF_VARS="$(primero_que_exista /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd)" \
    || error "faltan las variables OVMF (paquete ovmf)"

ACEL=(-cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACEL=(-enable-kvm -cpu host)
else
    echo "Aviso: sin KVM, el arranque será lento."
fi

mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d)"
QEMU_PID=""

limpiar() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -rf "$TRABAJO"
}
trap limpiar EXIT

monitor() {
    # Envía un comando al monitor de QEMU.
    printf '%s\n' "$1" | socat - "UNIX-CONNECT:$TRABAJO/monitor.sock" >/dev/null 2>&1 || true
}

# probar_modo <modo>  → 0 si arrancó bien, 1 si no.
probar_modo() {
    local modo="$1"
    local serie="$DIR_PRUEBAS/$modo-serie.log"
    local captura="$DIR_PRUEBAS/$modo-pantalla.png"
    local capa="$TRABAJO/$modo.qcow2"
    local args=()

    rm -f "$serie" "$captura"
    qemu-img create -q -f qcow2 -b "$IMG" -F raw "$capa"

    case "$modo" in
        uefi-sb)
            cp "$OVMF_VARS_MS" "$TRABAJO/vars-$modo.fd"
            args+=(-machine q35,smm=on
                   -global driver=cfi.pflash01,property=secure,value=on
                   -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE_SB"
                   -drive "if=pflash,format=raw,unit=1,file=$TRABAJO/vars-$modo.fd")
            ;;
        uefi)
            cp "$OVMF_VARS" "$TRABAJO/vars-$modo.fd"
            args+=(-machine q35
                   -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
                   -drive "if=pflash,format=raw,unit=1,file=$TRABAJO/vars-$modo.fd")
            ;;
        bios)
            args+=(-machine q35)
            ;;
        *) error "modo desconocido: $modo" ;;
    esac

    case "$BUS" in
        usb)
            args+=(-device qemu-xhci,id=xhci
                   -drive "if=none,id=disco,format=qcow2,file=$capa"
                   -device usb-storage,bus=xhci.0,drive=disco,bootindex=1)
            ;;
        virtio)
            args+=(-drive "if=virtio,format=qcow2,file=$capa")
            ;;
        *) error "bus desconocido: $BUS" ;;
    esac

    args+=("${ACEL[@]}" -smp 2 -m "$MEM" -vga std -display none
           -nic user,model=virtio-net-pci
           -serial "file:$serie"
           -monitor "unix:$TRABAJO/monitor.sock,server,nowait")

    printf '\n\e[1m--- Modo %s (disco %s) ---\e[0m\n' "$modo" "$BUS"
    qemu-system-x86_64 "${args[@]}" &
    QEMU_PID=$!

    local inicio=$SECONDS resultado=1 motivo="tiempo agotado (${TIMEOUT}s)"
    while (( SECONDS - inicio < TIMEOUT )); do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            motivo="QEMU terminó antes de tiempo"
            break
        fi
        if grep -q "LLEVIX-ARRANQUE-FIN" "$serie" 2>/dev/null; then
            local linea modo_real gestor
            # Sin "^": el firmware puede dejar códigos de pantalla antes del texto.
            linea="$(grep -a -o -m1 'LLEVIX-ARRANQUE modo=[^ ]* gestor=[^ [:cntrl:]]*' "$serie" || true)"
            modo_real="$(sed -n 's/.*modo=\([^ ]*\).*/\1/p' <<<"$linea")"
            gestor="$(sed -n 's/.*gestor=\([^ ]*\).*/\1/p' <<<"$linea")"
            if [[ "$modo_real" != "$modo" ]]; then
                motivo="arrancó en modo '$modo_real' y se esperaba '$modo'"
            elif [[ "$gestor" != "active" ]]; then
                motivo="el gestor de sesión no está activo ('$gestor')"
            else
                resultado=0
                motivo="llegó al escritorio en $((SECONDS - inicio)) s"
                # Unos segundos más para que la captura muestre el escritorio.
                sleep 15
            fi
            break
        fi
        sleep 5
    done

    monitor "screendump $captura -f png"
    sleep 2
    monitor "quit"
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""

    if (( resultado == 0 )); then
        printf '\e[32mOK\e[0m    %s: %s\n' "$modo" "$motivo"
    else
        printf '\e[31mFALLA\e[0m %s: %s\n' "$modo" "$motivo"
        echo "Últimas líneas del puerto serie:"
        tail -n 40 "$serie" 2>/dev/null || echo "(vacío)"
    fi
    if [[ -f "$serie" ]] && grep -q "Unidades con fallo" "$serie"; then
        sed -n '/Unidades con fallo/,/LLEVIX-ARRANQUE-FIN/p' "$serie"
    fi
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
