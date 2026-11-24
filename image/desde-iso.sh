#!/usr/bin/env bash
# desde-iso.sh — Construye una variante del catálogo a partir de la ISO oficial de la distro,
# usando el instalador de "Trae tu ISO" (fase 8) dentro de QEMU.
#
# Uso:   sudo ./image/desde-iso.sh <variante> <llevix-instalador.img> <distro.iso>
# Sale:  out/llevix-<variante>.img y out/llevix-<variante>.paquetes.txt
#
# Pasos:
# 1. Copia la imagen del instalador y guarda la ISO en su zona reservada (modo=imagen).
# 2. Arranca en QEMU: el instalador instala la distro y apaga.
# 3. Con loop devices: borra el instalador viejo, aplica la marca de Llevix, agrega el
#    agente de QEMU (para las pruebas), comprueba el escritorio completo, guarda la lista
#    de paquetes y libera el espacio vacío.
#
# SEGURIDAD: solo trabaja con ARCHIVOS .img y loop devices (comprobados), nunca con discos.

set -euo pipefail

DIR_IMAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_REPO="$(dirname "$DIR_IMAGE")"
OUT_DIR="${LLEVIX_OUT:-$DIR_REPO/out}"
INICIO_RESERVA=$((16 * 1024 * 1024 * 1024))
ENCABEZADO=$((1024 * 1024))
MAX_ISO=$((8 * 1024 * 1024 * 1024 - ENCABEZADO))
TIMEOUT="${LLEVIX_TIMEOUT_INSTALAR:-3600}"

paso()  { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
error() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }
asegurar_loop() { [[ "$1" =~ ^/dev/loop[0-9]+(p[0-9]+)?$ ]] || error "dispositivo inesperado: $1"; }

[[ $# -eq 3 ]] || error "uso: sudo $0 <variante> <instalador.img> <distro.iso>"
VARIANTE="$1"; INSTALADOR="$(realpath "$2")"; ISO="$(realpath "$3")"
[[ "$VARIANTE" =~ ^[a-z0-9.-]+$ ]] || error "nombre de variante no válido"
CONF="$DIR_IMAGE/distros/$VARIANTE.conf"
[[ -f "$CONF" && -f "$INSTALADOR" && -f "$ISO" ]] || error "falta $CONF, la imagen del instalador o la ISO"
[[ $EUID -eq 0 ]] || error "necesita root (loop devices)"
# shellcheck source=/dev/null
source "$CONF"
[[ "${TIPO:-}" == "desde-iso" ]] || error "$VARIANTE no es una variante desde ISO"
: "${NOMBRE_VISIBLE:?falta en $CONF}"

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/llevix-$VARIANTE.img"
LOOP=""; ROOT=""; TRABAJO="$(mktemp -d)"
limpiar() {
    set +e
    if [[ -n "$ROOT" ]]; then
        findmnt -R -n -l -o TARGET "$ROOT" 2>/dev/null | sort -r | while read -r p; do umount "$p" 2>/dev/null || umount -l "$p"; done
    fi
    [[ -n "$LOOP" ]] && losetup -d "$LOOP"
    rm -rf "$TRABAJO"
}
trap limpiar EXIT

# ---------- 1. Imagen del instalador + ISO ----------

tam_iso="$(stat -c %s "$ISO")"
(( tam_iso <= MAX_ISO )) || error "la ISO es demasiado grande ($tam_iso bytes)"
paso "Preparando $IMG con $(basename "$ISO")"
rm -f "$IMG"
cp --sparse=always "$INSTALADOR" "$IMG"
inicio_p4=$(( $(partx -g -o START -n 4 "$IMG" | tr -d ' ') * 512 ))
printf 'LLEVIX-ISO 1\ntamano=%s\nsha256=%s\nnombre=%s\nmodo=imagen\n' \
    "$tam_iso" "$(sha256sum "$ISO" | cut -d' ' -f1)" "$(basename "$ISO")" > "$TRABAJO/encabezado"
# dd sobre un ARCHIVO de imagen (nunca sobre un dispositivo).
dd if="$TRABAJO/encabezado" of="$IMG" bs=1M conv=notrunc oflag=seek_bytes seek=$((inicio_p4 + INICIO_RESERVA)) status=none
dd if="$ISO" of="$IMG" bs=4M conv=notrunc,sparse oflag=seek_bytes seek=$((inicio_p4 + INICIO_RESERVA + ENCABEZADO)) status=none

# ---------- 2. Instalar en QEMU ----------

paso "Instalando la distro en QEMU (el instalador apaga al terminar)"
DIR_PRUEBAS="$OUT_DIR/pruebas"
mkdir -p "$DIR_PRUEBAS"
# shellcheck source=tests/lib/qemu.sh
source "$DIR_REPO/tests/lib/qemu.sh"
qemu_requisitos
qemu_iniciar "desde-iso-$VARIANTE" uefi "$IMG" raw
inicio=$SECONDS
while qemu_vivo && (( SECONDS - inicio < TIMEOUT )); do sleep 10; done
if qemu_vivo; then
    qemu_captura "$DIR_PRUEBAS/desde-iso-$VARIANTE.png"
    qemu_matar
    tail -n 40 "$QEMU_SERIE"
    error "el instalador no terminó en ${TIMEOUT}s"
fi
grep -a -o 'LLEVIX-INSTALADOR paso=[^[:cntrl:]]*' "$QEMU_SERIE" | sed 's/^/  /' || true
resultado="$(grep -a -o 'LLEVIX-INSTALADOR resultado=[^[:cntrl:]]*' "$QEMU_SERIE" | tail -n1 || true)"
[[ "$resultado" == *"resultado=ok"* ]] || { tail -n 40 "$QEMU_SERIE"; error "el instalador falló: ${resultado:-sin resultado}"; }
echo "Instalado en $((SECONDS - inicio)) s: $resultado"

# ---------- 3. Terminar la imagen ----------

paso "Terminando la imagen"
LOOP="$(losetup --find --show --partscan "$IMG")"
asegurar_loop "$LOOP"
udevadm settle
P_SIS="${LOOP}p4"; P_ESP="${LOOP}p3"
for p in "$P_SIS" "$P_ESP"; do
    for _ in $(seq 20); do [[ -b "$p" ]] && break; sleep 0.5; done
    asegurar_loop "$p"
done

ROOT="$TRABAJO/raiz"
mkdir -p "$ROOT" "$TRABAJO/tope"
mount -o subvolid=5 "$P_SIS" "$TRABAJO/tope"
if [[ -d "$TRABAJO/tope/@llevix-instalador" ]]; then
    btrfs -q subvolume delete "$TRABAJO/tope/@llevix-instalador"
fi
umount "$TRABAJO/tope"

mount -o subvol=@,compress=zstd:3,noatime "$P_SIS" "$ROOT"
mount -o subvol=@home "$P_SIS" "$ROOT/home"
mount "$P_ESP" "$ROOT/boot/efi"
mount --bind /dev "$ROOT/dev"
mount -t devpts devpts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount -t tmpfs tmpfs "$ROOT/run"
mkdir -p "$ROOT/run/systemd/resolve"
cp -L /etc/resolv.conf "$ROOT/run/systemd/resolve/stub-resolv.conf"
cp -L /etc/resolv.conf "$ROOT/run/systemd/resolve/resolv.conf"
en_chroot() {
    chroot "$ROOT" /usr/bin/env -i HOME=/root LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -euo pipefail -c "$1"
}
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod +x "$ROOT/usr/sbin/policy-rc.d"

# Lo que necesita la capa de Llevix (ampliar LLEVIX-DATOS en el primer arranque, ajustes
# de disco) y el agente de QEMU (solo se activa en una máquina virtual; lo usan las pruebas).
en_chroot "apt-get update -q && apt-get install -y -q gdisk exfatprogs btrfs-progs jq hdparm sg3-utils qemu-guest-agent"

paso "Comprobando que el escritorio está completo"
en_chroot "$(cat "$DIR_IMAGE/lib/verificar-escritorio.sh")"

paso "Marca: $NOMBRE_VISIBLE"
en_chroot "dpkg-divert --quiet --local --rename --add /usr/lib/os-release"
sed -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"$NOMBRE_VISIBLE\"/" \
    "$ROOT/usr/lib/os-release.distrib" > "$ROOT/usr/lib/os-release"
cat > "$ROOT/etc/llevix/version" <<EOF
VARIANTE=$VARIANTE
NOMBRE="$NOMBRE_VISIBLE"
ISO="$(basename "$ISO")"
FECHA=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git -C "$DIR_REPO" rev-parse --short HEAD 2>/dev/null || echo desconocido)
EOF

paso "Lista de paquetes"
en_chroot "dpkg-query -W -f='\${Package}\t\${Version}\t\${source:Package}\t\${source:Version}\n'" \
    | sort > "$OUT_DIR/llevix-$VARIANTE.paquetes.txt"
wc -l < "$OUT_DIR/llevix-$VARIANTE.paquetes.txt"

paso "Limpiando"
rm -f "$ROOT/usr/sbin/policy-rc.d"
en_chroot "apt-get clean"
# Las listas de paquetes quedan en la imagen (comprimidas: overlay/etc/apt/apt.conf.d/
# 80llevix-indices). Sin ellas, el sistema avisa que la información de software está
# desactualizada y, al conectarse a internet, descarga y escribe todas de golpe: en una
# memoria USB lenta eso no deja abrir nada durante minutos.
rm -rf "$ROOT"/var/lib/apt/lists/*
if ! en_chroot "apt-get -o Acquire::Retries=5 update -q"; then
    echo "aviso: no se pudieron descargar las listas de paquetes; la imagen queda sin ellas" >&2
    rm -rf "$ROOT"/var/lib/apt/lists/*
fi
rm -rf "$ROOT"/var/lib/apt/lists/partial/* "$ROOT"/var/lib/apt/lists/lock     "$ROOT"/var/cache/apt/*.bin "$ROOT"/tmp/* "$ROOT"/var/tmp/*
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/boot/efi/LLEVIX-ERROR.txt"
df -h "$ROOT"
fstrim -v "$ROOT/boot/efi" || true
fstrim -v "$ROOT" || true
sync
paso "Listo: $IMG"
du -h --apparent-size "$IMG"; du -h "$IMG"
