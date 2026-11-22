#!/usr/bin/env bash
# iso-propia-test.sh — Prueba "Trae tu ISO" de punta a punta con una ISO real.
#
# Uso: ./tests/iso-propia-test.sh <llevix-instalador.img> <distro.iso>
#
# 1. Prepara un disco simulado de 32 GiB como lo haría el creador: imagen del instalador,
#    encabezado + ISO en la zona reservada de la partición 4 y llevix-config.json en la ESP.
# 2. Arranca con UEFI + Secure Boot: el instalador copia la distro y reinicia.
# 3. Comprueba el sistema instalado por el informe del puerto serie: escritorio, cuenta,
#    red, sonido, navegador y Datos. Luego vuelve a arrancar en modo BIOS.
#
# No necesita root y nunca toca discos reales (solo archivos).

set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR_PRUEBAS="${LLEVIX_TEST_DIR:-$DIR_REPO/out/pruebas}"
TIMEOUT_INSTALAR="${LLEVIX_TEST_TIMEOUT_INSTALAR:-2700}"
TIMEOUT="${LLEVIX_TEST_TIMEOUT:-1200}"
USUARIO="iso"

INICIO_RESERVA=$((16 * 1024 * 1024 * 1024))
ENCABEZADO=$((1024 * 1024))
MAX_ISO=$((8 * 1024 * 1024 * 1024 - ENCABEZADO))

# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"

[[ $# -eq 2 ]] || { echo "uso: $0 <instalador.img> <distro.iso>" >&2; exit 2; }
IMG="$(realpath "$1")"; ISO="$(realpath "$2")"
[[ -f "$IMG" && -f "$ISO" ]] || { echo "no existe la imagen o la ISO" >&2; exit 2; }
for h in mcopy partx openssl sha256sum; do
    command -v "$h" >/dev/null || { echo "falta $h" >&2; exit 2; }
done
qemu_requisitos

mkdir -p "$DIR_PRUEBAS"
TRABAJO="$(mktemp -d "$DIR_PRUEBAS/iso.XXXXXX")"
trap 'qemu_matar; rm -rf "$TRABAJO"' EXIT
NOMBRE="$(basename "$ISO" .iso)"

fallos=0
ok()    { printf '  \e[32m[ok]\e[0m    %s\n' "$*"; }
falla() { printf '  \e[31m[falla]\e[0m %s\n' "$*"; fallos=$((fallos + 1)); }
info()  { grep -a -o "LLEVIX-INFO $1=[^[:cntrl:]]*" "$QEMU_SERIE" | tail -n1 | cut -d= -f2- || true; }

# ---------- 1. Disco simulado, como lo deja el creador ----------

tam_iso="$(stat -c %s "$ISO")"
(( tam_iso <= MAX_ISO )) || { echo "la ISO es demasiado grande para la zona reservada" >&2; exit 2; }
echo "Preparando el disco con $(basename "$ISO") ($((tam_iso / 1024 / 1024)) MiB)…"

"$DIR_REPO/tools/make-config.sh" --usuario "$USUARIO" --nombre-completo "Prueba ISO" \
    --contrasena "clave-iso" --idioma es_ES.UTF-8 --zona Europe/Madrid --teclado es \
    --hostname llevix-iso > "$TRABAJO/config.json"
preparar_disco "$IMG" "$TRABAJO/disco.img" 32G "$TRABAJO/config.json"

inicio_p4=$(( $(partx -g -o START -n 4 "$IMG" | tr -d ' ') * 512 ))
{
    printf 'LLEVIX-ISO 1\ntamano=%s\nsha256=%s\nnombre=%s\n' \
        "$tam_iso" "$(sha256sum "$ISO" | cut -d' ' -f1)" "$(basename "$ISO")"
} > "$TRABAJO/encabezado"
# Se escribe en un ARCHIVO (el disco simulado), nunca en un dispositivo.
dd if="$TRABAJO/encabezado" of="$TRABAJO/disco.img" bs=1M conv=notrunc,sparse \
    oflag=seek_bytes seek=$((inicio_p4 + INICIO_RESERVA)) status=none
dd if="$ISO" of="$TRABAJO/disco.img" bs=4M conv=notrunc,sparse \
    oflag=seek_bytes seek=$((inicio_p4 + INICIO_RESERVA + ENCABEZADO)) status=none

# ---------- 2. Instalación (UEFI + Secure Boot) ----------

echo; echo "Instalando $NOMBRE"
qemu_iniciar "iso-$NOMBRE" uefi-sb "$TRABAJO/disco.img" raw
inicio=$SECONDS
resultado=""
while (( SECONDS - inicio < TIMEOUT_INSTALAR )); do
    resultado="$(grep -a -o 'LLEVIX-INSTALADOR resultado=[^[:cntrl:]]*' "$QEMU_SERIE" | tail -n1 || true)"
    [[ -n "$resultado" ]] && break
    qemu_vivo || break
    sleep 10
done
grep -a -o 'LLEVIX-INSTALADOR paso=[^[:cntrl:]]*' "$QEMU_SERIE" | sed 's/^/  /' || true
if [[ "$resultado" == *"resultado=ok"* ]]; then
    ok "el instalador terminó en $((SECONDS - inicio)) s ($resultado)"
else
    falla "el instalador no terminó bien: ${resultado:-sin resultado}"
    qemu_captura "$DIR_PRUEBAS/iso-$NOMBRE-instalador.png"
    tail -n 40 "$QEMU_SERIE" || true
    exit 1
fi

# ---------- 3. Sistema instalado ----------

echo; echo "Primer arranque del sistema instalado (reinició solo)"
if qemu_esperar_informe "$TIMEOUT"; then
    qemu_captura "$DIR_PRUEBAS/iso-$NOMBRE-escritorio.png"
    echo "  sistema: $(info sistema)"
    if [[ "$INFORME_MODO" == "uefi-sb" ]]; then ok "arrancó con Secure Boot"; else falla "modo: $INFORME_MODO"; fi
    if [[ "$INFORME_GESTOR" == "active" ]]; then ok "llegó a la pantalla de inicio de sesión"; else falla "gestor de sesión: $INFORME_GESTOR"; fi
    if [[ "$INFORME_PRIMER_ARRANQUE" == *"resultado=ok"* ]]; then ok "se creó la cuenta del creador"; else falla "primer arranque: $INFORME_PRIMER_ARRANQUE"; fi
    if [[ ",$(info usuarios)," == *",$USUARIO,"* ]]; then ok "existe el usuario $USUARIO"; else falla "usuarios: $(info usuarios)"; fi
    if [[ "$(info red)" == connected* ]]; then ok "la red conecta"; else falla "red: $(info red)"; fi
    if [[ "$(info sonido)" == "si" ]]; then ok "hay tarjeta de sonido"; else falla "sonido: $(info sonido)"; fi
    if [[ "$(info navegador)" != "no" ]]; then ok "hay navegador ($(info navegador))"; else falla "no hay navegador"; fi
    if [[ "$(info datos)" == "/home/$USUARIO/Datos" ]]; then ok "Datos montado en la carpeta personal"; else falla "datos: $(info datos)"; fi
else
    falla "el sistema instalado no llegó al escritorio"
    qemu_captura "$DIR_PRUEBAS/iso-$NOMBRE-escritorio.png"
    tail -n 60 "$QEMU_SERIE" || true
fi
qemu_matar

echo; echo "Arranque en modo BIOS"
qemu_iniciar "iso-$NOMBRE-bios" bios "$TRABAJO/disco.img" raw
if qemu_esperar_informe "$TIMEOUT"; then
    if [[ "$INFORME_MODO" == "bios" && "$INFORME_GESTOR" == "active" ]]; then
        ok "también arranca en BIOS hasta el escritorio"
    else
        falla "BIOS: modo=$INFORME_MODO gestor=$INFORME_GESTOR"
    fi
else
    falla "no arrancó en modo BIOS"
    tail -n 40 "$QEMU_SERIE" || true
fi
qemu_matar

echo
if (( fallos == 0 )); then
    printf '\e[32mISO propia (%s): todo bien.\e[0m\n' "$NOMBRE"
else
    printf '\e[31mISO propia (%s): %d comprobación(es) fallaron.\e[0m\n' "$NOMBRE" "$fallos"
fi
(( fallos == 0 ))
