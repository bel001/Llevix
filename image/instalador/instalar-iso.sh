#!/usr/bin/env bash
# instalar-iso.sh — "Trae tu ISO": instala en este disco la distro de una ISO elegida por
# el usuario (familia Ubuntu: Ubuntu y sabores, Linux Mint, Zorin OS, elementary…).
#
# Lo ejecuta llevix-instalar-iso.service en la imagen "Llevix instalador". El creador
# dejó la ISO dentro de la partición del sistema, en una zona que btrfs todavía no usa:
#
#   partición 4 (LLEVIX-SISTEMA, 24 GiB)
#   ├── 0 a 16 GiB      btrfs (este instalador, en el subvolumen @)
#   └── 16 GiB a 24 GiB reservado: encabezado (1 MiB) + ISO (hasta 8 GiB - 1 MiB)
#
# Pasos: verificar la ISO → copiar su sistema (squashfs) a un subvolumen nuevo → quitar
# los paquetes del modo "en vivo" → kernel, initramfs y GRUB → capa de Llevix → el nuevo
# sistema pasa a ser @ (el instalador queda como @llevix-instalador y lo borra el primer
# arranque) → btrfs ocupa la zona de la ISO → ampliar LLEVIX-DATOS → reiniciar.
# Si algo falla, el disco sigue siendo el instalador y se explica el motivo.
#
# SEGURIDAD: solo trabaja en el disco desde el que arrancó (el que contiene /).

set -euo pipefail

INICIO_RESERVA=$((16 * 1024 * 1024 * 1024))   # bytes desde el inicio de la partición 4
ENCABEZADO=$((1024 * 1024))
MAX_ISO=$((8 * 1024 * 1024 * 1024 - ENCABEZADO))
CAPA=/usr/share/llevix/capa
OPC_BTRFS="compress=zstd:3,noatime"

T=/run/llevix-iso          # puntos de montaje temporales
ISO_LOOP=""
LIMPIAR=()
RENOMBRADO=0

serie() { { echo "LLEVIX-INSTALADOR $*" > /dev/ttyS0; } 2>/dev/null || true; }
paso()  { echo; echo "==> $*"; serie "paso=$*"; }

limpiar() {
    local i
    set +e
    for (( i=${#LIMPIAR[@]}-1; i>=0; i-- )); do bash -c "${LIMPIAR[i]}" >/dev/null 2>&1; done
    LIMPIAR=()
}

fallar() {
    trap - ERR
    set +e
    echo
    echo "Llevix no pudo instalar la ISO: $1"
    serie "resultado=error motivo=$1"
    # Desmonta todo menos la raíz de btrfs, para poder deshacer.
    findmnt -rno TARGET | grep "^$T/" | grep -vx "$T/tope" | sort -r | while read -r m; do umount -l "$m"; done
    if mountpoint -q "$T/tope"; then
        if (( RENOMBRADO )) && [[ -d "$T/tope/@llevix-instalador" ]]; then
            # El instalador vuelve a ser @: el disco queda como estaba antes.
            mv "$T/tope/@" "$T/tope/@nuevo"
            mv "$T/tope/@llevix-instalador" "$T/tope/@"
        fi
        [[ -d "$T/tope/@nuevo" ]] && btrfs -q subvolume delete "$T/tope/@nuevo"
    fi
    limpiar
    {
        printf 'Llevix no pudo instalar la ISO elegida.\r\n\r\nMotivo: %s\r\n\r\n' "$1"
        printf 'Tu PC no se modificó. Puedes volver a preparar el disco con el creador de\r\n'
        printf 'Llevix eligiendo otra ISO o una de las distros del catálogo.\r\n'
    } > /boot/efi/LLEVIX-ERROR.txt 2>/dev/null
    echo
    echo "Puedes apagar la PC con el botón de encendido. El motivo quedó en LLEVIX-ERROR.txt"
    exit 1
}
trap 'fallar "falló un comando inesperadamente (línea $LINENO)"' ERR

monta() { mkdir -p "$2"; mount "${@:3}" "$1" "$2"; LIMPIAR+=("umount -l '$2'"); }

# ---------- Disco y encabezado ----------

paso "Buscando la ISO"
P_SIS="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
DISCO="/dev/$(lsblk -no PKNAME "$P_SIS" | head -n1)"
[[ -b "$P_SIS" && -b "$DISCO" ]] || fallar "no se encontró el disco de Llevix"
[[ "$(cat "/sys/class/block/$(basename "$P_SIS")/partition")" == "4" ]] || fallar "el sistema no está en la partición 4"
P_DATOS="$(lsblk -lnpo NAME,PARTLABEL "$DISCO" | awk '$2 == "LLEVIX-DATOS" {print $1}')"
[[ -b "$P_DATOS" ]] || fallar "no se encontró la partición LLEVIX-DATOS"
UUID_SIS="$(blkid -s UUID -o value "$P_SIS")"
UUID_ESP="$(findmnt -no UUID /boot/efi)"

mkdir -p "$T"
# Se lee con un loop device de solo lectura (nunca se escribe en el disco con dd).
cab_loop="$(losetup --find --show --read-only --offset "$INICIO_RESERVA" --sizelimit 4096 "$P_SIS")"
encabezado="$(tr -d '\0' < "$cab_loop")"
losetup -d "$cab_loop"
[[ "$(head -n1 <<<"$encabezado")" == "LLEVIX-ISO 1" ]] || fallar "no hay ninguna ISO guardada en el disco"
leer() { sed -n "s/^$1=//p" <<<"$encabezado" | head -n1; }
tamano="$(leer tamano)"; sha="$(leer sha256)"
# modo=imagen: lo usa image/desde-iso.sh para construir el catálogo en CI (no amplía los
# datos y apaga al terminar). Sin modo (lo que escribe el creador): instalación normal.
modo="$(leer modo)"
[[ "$modo" == "imagen" ]] || modo="usuario"
nombre_iso="$(leer nombre | tr -cd 'A-Za-z0-9 ._()+-' | cut -c1-80)"
if ! [[ "$tamano" =~ ^[0-9]+$ ]] || (( tamano <= 0 || tamano > MAX_ISO )); then fallar "el tamaño de la ISO no es válido"; fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fallar "la suma SHA256 de la ISO no es válida"
echo "ISO: ${nombre_iso:-sin nombre} ($((tamano / 1024 / 1024)) MiB)"

ISO_LOOP="$(losetup --find --show --read-only --offset $((INICIO_RESERVA + ENCABEZADO)) --sizelimit "$tamano" "$P_SIS")"
LIMPIAR+=("losetup -d $ISO_LOOP")

paso "Comprobando la ISO (SHA256)"
[[ "$(sha256sum "$ISO_LOOP" | cut -d' ' -f1)" == "$sha" ]] || fallar "la ISO guardada está dañada (la suma SHA256 no coincide)"

monta "$ISO_LOOP" "$T/iso" -o ro -t iso9660

# ---------- Qué sistema trae la ISO ----------

paso "Leyendo la ISO"
capas=()
quitar=""
if [[ -f "$T/iso/casper/install-sources.yaml" ]]; then
    # Ubuntu 24.04 y posteriores: sistema en capas (minimal → minimal.standard → …).
    ruta="$(awk '/^- /{d=0; p=""} /default: true/{d=1} /path:/{p=$2} d && p {print p; exit}' "$T/iso/casper/install-sources.yaml")"
    [[ -n "$ruta" ]] || ruta="$(awk '/path:/{print $2; exit}' "$T/iso/casper/install-sources.yaml")"
    base="${ruta%.squashfs}"
    prefijo=""
    IFS=. read -ra partes <<<"$base"
    for p in "${partes[@]}"; do
        prefijo="${prefijo:+$prefijo.}$p"
        [[ -f "$T/iso/casper/$prefijo.squashfs" ]] || fallar "falta la capa $prefijo.squashfs"
        capas+=("$T/iso/casper/$prefijo.squashfs")
    done
elif [[ -f "$T/iso/casper/filesystem.squashfs" ]]; then
    capas=("$T/iso/casper/filesystem.squashfs")
    [[ -f "$T/iso/casper/filesystem.manifest-remove" ]] && quitar="$T/iso/casper/filesystem.manifest-remove"
else
    fallar "esta ISO no es compatible (Llevix acepta ISOs de la familia Ubuntu: Ubuntu, Mint, Zorin, elementary…)"
fi
kernel="$(find "$T/iso/casper" -maxdepth 1 -name "vmlinuz*" -type f | sort | head -n1)"
[[ -f "$kernel" ]] || fallar "la ISO no trae kernel en casper/"
nombre_distro="$(head -n1 "$T/iso/.disk/info" 2>/dev/null | tr -cd 'A-Za-z0-9 ._()"+-' | cut -c1-80)"
echo "Distro: ${nombre_distro:-desconocida}; capas: ${#capas[@]}"

# Secure Boot: este disco arranca con el shim y GRUB firmados de Ubuntu, que solo
# aceptan kernels firmados por Canonical (los de Ubuntu, Mint, Zorin, elementary…).
sb=0
for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -r "$f" && "$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')" == "1" ]] && sb=1
done
firmante="$(sbverify --list "$kernel" 2>/dev/null | sed -n 's/.*subject: //p' | head -n3 | tr '\n' ' ')"
echo "Kernel firmado por: ${firmante:-nadie}"
if [[ "$firmante" != *Canonical* ]]; then
    if (( sb )); then
        fallar "el kernel de esta ISO no está firmado por Canonical y no arrancaría con Arranque seguro. Elige una distro del catálogo (no desactives Secure Boot)"
    fi
    echo "Aviso: el kernel no está firmado por Canonical; solo arrancará sin Arranque seguro."
fi

# ---------- Copiar el sistema ----------

paso "Copiando el sistema de la ISO (puede tardar varios minutos)"
monta "$P_SIS" "$T/tope" -o "subvolid=5,$OPC_BTRFS"
[[ ! -e "$T/tope/@nuevo" ]] || btrfs -q subvolume delete "$T/tope/@nuevo"
btrfs -q subvolume create "$T/tope/@nuevo"

capas_montadas=()
i=0
for c in "${capas[@]}"; do
    monta "$c" "$T/capa$i" -o ro -t squashfs
    capas_montadas=("$T/capa$i" "${capas_montadas[@]}")   # la última capa va arriba
    i=$((i + 1))
done
if (( ${#capas_montadas[@]} == 1 )); then
    origen="${capas_montadas[0]}"
else
    inferiores="$(IFS=:; echo "${capas_montadas[*]}")"
    monta overlay "$T/origen" -t overlay -o "lowerdir=$inferiores"
    origen="$T/origen"
fi
rsync -aHAX --numeric-ids --info=progress2 "$origen/" "$T/tope/@nuevo/"

# ---------- Configurar el sistema nuevo ----------

D="$T/destino"
monta "$P_SIS" "$D" -o "subvol=@nuevo,$OPC_BTRFS"
for m in dev dev/pts proc sys run; do mkdir -p "$D/$m"; done
monta /dev "$D/dev" --bind
monta devpts "$D/dev/pts" -t devpts
monta proc "$D/proc" -t proc
monta sysfs "$D/sys" -t sysfs
monta tmpfs "$D/run" -t tmpfs
mkdir -p "$D/boot/efi"
monta /boot/efi "$D/boot/efi" --bind
cp -L /etc/resolv.conf "$D/run/resolv-instalador.conf" 2>/dev/null || true

en_destino() {
    chroot "$D" /usr/bin/env -i HOME=/root LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -euo pipefail -c "$1"
}
printf '#!/bin/sh\nexit 101\n' > "$D/usr/sbin/policy-rc.d"; chmod +x "$D/usr/sbin/policy-rc.d"
LIMPIAR+=("rm -f '$D/usr/sbin/policy-rc.d'")

paso "Quitando los programas del modo en vivo"
{
    [[ -n "$quitar" ]] && awk '{print $1}' "$quitar" | sed 's/:.*$//'
    printf '%s\n' casper lupin-casper ubiquity ubiquity-casper ubiquity-frontend-gtk ubiquity-frontend-kde \
        ubiquity-slideshow-ubuntu ubiquity-ubuntu-artwork live-installer calamares oem-config \
        oem-config-gtk ubuntu-desktop-bootstrap
} | sort -u > "$D/tmp/quitar"
# shellcheck disable=SC2016  # se expande dentro del chroot
en_destino 'instalados="$(dpkg-query -W -f="\${Package}\n" | sort -u)"
    lista="$(sort -u /tmp/quitar | comm -12 - <(echo "$instalados") | tr "\n" " ")"
    if [ -n "$lista" ]; then
        apt-get -y purge $lista >/dev/null 2>&1 || for p in $lista; do apt-get -y purge "$p" >/dev/null 2>&1 || true; done
    fi
    rm -f /tmp/quitar'

paso "Kernel e initramfs"
version_kernel() {
    find "$D/usr/lib/modules/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true
}
version="$(version_kernel)"
if [[ -z "$version" ]]; then
    # Ubuntu 24.04+ instala el kernel aparte, desde los paquetes que trae la propia ISO
    # (carpetas dists/ y pool/). Se hace igual, sin internet.
    echo "El sistema de la ISO no trae kernel: se instala desde los paquetes de la ISO."
    suite="$(find "$T/iso/dists" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n1)"
    [[ -n "$suite" && -d "$T/iso/pool" ]] || fallar "la ISO no trae kernel ni paquetes para instalarlo"
    mkdir -p "$D/media/llevix-iso"
    monta "$T/iso" "$D/media/llevix-iso" --bind
    componentes="$(find "$T/iso/dists/$suite" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
    echo "deb [trusted=yes] file:///media/llevix-iso $suite ${componentes:-main restricted}" > "$D/tmp/llevix-iso.list"
    solo_iso="-o Dir::Etc::sourcelist=/tmp/llevix-iso.list -o Dir::Etc::sourceparts=/nonexistent -o APT::Get::List-Cleanup=0"
    en_destino "apt-get $solo_iso update" || fallar "no se pudieron leer los paquetes de la ISO"
    # El kernel que pide la ISO (install-sources.yaml) o, si no lo dice, el genérico (HWE primero).
    meta="$(grep -Eo 'linux-generic(-hwe-[0-9.]+)?' "$T/iso/casper/install-sources.yaml" 2>/dev/null | head -n1 || true)"
    if [[ -z "$meta" ]]; then
        meta="$(en_destino "apt-cache $solo_iso pkgnames linux-generic" | grep -E '^linux-generic(-hwe-[0-9.]+)?$' | sort -r | head -n1 || true)"
    fi
    [[ -n "$meta" ]] || fallar "la ISO no trae un paquete de kernel"
    echo "Instalando $meta desde la ISO"
    en_destino "apt-get $solo_iso -y --no-install-recommends install $meta" || fallar "no se pudo instalar el kernel desde la ISO"
    rm -f "$D/tmp/llevix-iso.list"
    umount -l "$D/media/llevix-iso" && rmdir "$D/media/llevix-iso" || true
    version="$(version_kernel)"
fi
[[ -n "$version" ]] || fallar "la ISO no trae módulos del kernel"
[[ -f "$D/boot/vmlinuz-$version" ]] || cp "$kernel" "$D/boot/vmlinuz-$version"
ln -sf "vmlinuz-$version" "$D/boot/vmlinuz"
ln -sf "initrd.img-$version" "$D/boot/initrd.img"

paso "Capa de Llevix (portabilidad, cuidado del disco, primer arranque)"
cp -a "$CAPA/overlay/." "$D/"
install -D -m 0755 "$CAPA/firstboot.sh" "$D/usr/lib/llevix/firstboot.sh"
install -D -m 0644 "$CAPA/llevix-firstboot.service" "$D/usr/lib/systemd/system/llevix-firstboot.service"
install -D -m 0755 "$CAPA/report.sh" "$D/usr/lib/llevix/report.sh"
install -D -m 0755 "$CAPA/jq" "$D/usr/lib/llevix/jq"
install -D -m 0644 "$CAPA/llevix-config.md" "$D/usr/share/doc/llevix/llevix-config.md"
mkdir -p "$D/etc/llevix" "$D/var/lib/llevix" "$D/.snapshots" "$D/etc/default/grub.d"
cat > "$D/etc/llevix/version" <<EOF
VARIANTE=iso-propia
NOMBRE="${nombre_distro:-ISO propia}"
ISO="${nombre_iso}"
FECHA=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cp /etc/default/grub.d/llevix.cfg "$D/etc/default/grub.d/llevix.cfg"
for u in llevix-estado-arranque.service llevix-firstboot.service llevix-disco-sistema.service fstrim.timer tmp.mount; do
    systemctl --root="$D" enable "$u" >/dev/null 2>&1 || echo "Aviso: no se pudo activar $u"
done

cat > "$D/etc/fstab" <<EOF
# Llevix: todo por UUID, nunca por /dev/sdX (el disco cambia de nombre en cada PC).
UUID=$UUID_SIS  /          btrfs  subvol=@,$OPC_BTRFS      0  0
UUID=$UUID_SIS  /home      btrfs  subvol=@home,$OPC_BTRFS  0  0
UUID=$UUID_SIS  /.snapshots btrfs subvol=@snapshots,$OPC_BTRFS 0  0
UUID=$UUID_ESP  /boot/efi  vfat   umask=0077,nofail        0  1
EOF
echo "llevix" > "$D/etc/hostname"
sed -i '/^127\.0\.1\.1/d' "$D/etc/hosts" 2>/dev/null || true
echo "127.0.1.1   llevix" >> "$D/etc/hosts"
: > "$D/etc/machine-id"
rm -f "$D"/etc/NetworkManager/system-connections/* 2>/dev/null || true

if ! en_destino "update-initramfs -c -k $version >/dev/null 2>&1 || update-initramfs -u -k $version"; then
    fallar "no se pudo crear el initramfs"
fi
[[ -f "$D/boot/initrd.img-$version" ]] || fallar "no se creó el initramfs"

# Módulos de GRUB para BIOS: el núcleo de GRUB que ya está en el disco es el del
# instalador, así que sus módulos se copian al sistema nuevo.
mkdir -p "$D/boot/grub"
cp -a /boot/grub/i386-pc /boot/grub/fonts "$D/boot/grub/" 2>/dev/null || true

for m in boot/efi run sys proc dev/pts dev; do umount -l "$D/$m"; done
umount -l "$D"
LIMPIAR=()   # lo que quedaba por desmontar ya se desmontó
LIMPIAR+=("umount -l '$T/tope'" "losetup -d $ISO_LOOP")
for c in "$T"/origen "$T"/capa*; do mountpoint -q "$c" && umount -l "$c"; done
umount -l "$T/iso"

# ---------- El sistema nuevo pasa a ser @ ----------

paso "Activando el sistema instalado"
[[ ! -e "$T/tope/@llevix-instalador" ]] || fallar "ya existe @llevix-instalador"
mv "$T/tope/@" "$T/tope/@llevix-instalador"
mv "$T/tope/@nuevo" "$T/tope/@"
RENOMBRADO=1

monta "$P_SIS" "$D" -o "subvol=@,$OPC_BTRFS"
monta /dev "$D/dev" --bind
monta proc "$D/proc" -t proc
monta sysfs "$D/sys" -t sysfs
monta /boot/efi "$D/boot/efi" --bind
if en_destino "command -v grub-mkconfig" >/dev/null 2>&1; then
    en_destino "grub-mkconfig -o /boot/grub/grub.cfg" || fallar "no se pudo crear el menú de arranque"
fi
if ! grep -q "rootflags=subvol=@" "$D/boot/grub/grub.cfg" 2>/dev/null; then
    # La distro no trae grub-mkconfig (o no detectó el subvolumen): menú escrito a mano.
    cat > "$D/boot/grub/grub.cfg" <<EOF
set timeout=3
search --no-floppy --fs-uuid --set=root $UUID_SIS
menuentry '${nombre_distro:-Linux} (Llevix)' {
    linux /@/boot/vmlinuz root=UUID=$UUID_SIS ro rootflags=subvol=@ quiet splash
    initrd /@/boot/initrd.img
}
menuentry '${nombre_distro:-Linux} (Llevix, modo gráficos seguros)' {
    linux /@/boot/vmlinuz root=UUID=$UUID_SIS ro rootflags=subvol=@ nomodeset
    initrd /@/boot/initrd.img
}
EOF
fi
rm -f "$D/usr/sbin/policy-rc.d"

# ---------- Espacio ----------

paso "Ampliando el espacio"
# btrfs pasa a ocupar también la zona donde estaba la ISO.
btrfs filesystem resize max "$T/tope" >/dev/null
if [[ "$modo" == "imagen" ]]; then
    # Construcción del catálogo en CI: la imagen se publica tal cual y los datos se
    # amplían en el disco de cada usuario, en su primer arranque. Se libera la zona
    # de la ISO para que la imagen ocupe poco.
    fstrim "$T/tope" >/dev/null 2>&1 || true
else
    # LLEVIX-DATOS (partición 1, al final) ocupa el resto del disco.
    sgdisk -e "$DISCO" >/dev/null 2>&1 || true
    inicio="$(sgdisk -i 1 "$DISCO" | awk '/^First sector:/ {print $3}')"
    sgdisk -d 1 -n "1:$inicio:0" -t 1:0700 -c 1:LLEVIX-DATOS "$DISCO" >/dev/null 2>&1 || true
    partx -u "$DISCO" || true
    udevadm settle
    mkfs.exfat -L LLEVIX "$P_DATOS" >/dev/null
    touch "$D/var/lib/llevix/datos-ampliados"
fi

RENOMBRADO=0   # desde aquí ya no se deshace: el sistema nuevo está completo
limpiar
sync
paso "Listo"
serie "resultado=ok distro=${nombre_distro:-desconocida}"
if [[ "$modo" == "imagen" ]]; then
    systemctl poweroff
    exit 0
fi
echo
echo "${nombre_distro:-La distro} quedó instalada. La PC se reiniciará en 10 segundos."
sleep 10
systemctl reboot
