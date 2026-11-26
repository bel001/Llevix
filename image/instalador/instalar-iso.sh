#!/usr/bin/env bash
# instalar-iso.sh — "Trae tu ISO": instala en este disco la distro de una ISO elegida por
# el usuario. Reconoce la familia de la ISO (familias.json) y usa su módulo
# (familias/<id>.sh); hoy: familia Ubuntu (Ubuntu y sabores, Linux Mint, Zorin OS…).
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
FAMILIAS=/usr/lib/llevix/familias   # familias.json y un <id>.sh por familia
JQ="$CAPA/jq"
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
    # En una subshell (por ejemplo dentro de "$(...)") solo se sale: el proceso principal
    # recibe el error y deshace todo una sola vez.
    if [[ "$BASHPID" != "$$" ]]; then exit 1; fi
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

# Ejecuta una función de la familia con el aviso de error (trap ERR) activo también dentro
# de ella (-E), como si su código estuviera escrito aquí.
en_familia() { set -E; "$@"; set +E; }

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
# La familia se reconoce por cómo está hecha la ISO, no por su nombre (familias.json).
familia=""
# shellcheck disable=SC2016  # $id es una variable de jq, no de bash
while IFS=$'\t' read -r id archivo; do
    # Las rutas de familias.json son relativas y sin "..": no salen de la ISO.
    [[ "$archivo" =~ ^[A-Za-z0-9._/-]+$ && "$archivo" != *..* && "$id" =~ ^[a-z0-9-]+$ ]] || continue
    if [[ -z "$familia" && -e "$T/iso/$archivo" ]]; then familia="$id"; fi
done < <("$JQ" -r '.familias[] | select(.soportada) | .id as $id | .archivos[] | [$id, .] | @tsv' "$FAMILIAS/familias.json")
if [[ -z "$familia" ]]; then
    fallar "esta ISO no es compatible (Llevix reconoce: $("$JQ" -r '[.familias[] | select(.soportada) | .ejemplos[]] | join(", ")' "$FAMILIAS/familias.json"))"
fi
# shellcheck disable=SC2016  # $id es una variable de jq, no de bash
nombre_familia="$("$JQ" -r --arg id "$familia" '.familias[] | select(.id == $id) | .nombre' "$FAMILIAS/familias.json")"
# shellcheck disable=SC2016  # $id es una variable de jq, no de bash
firmante_esperado="$("$JQ" -r --arg id "$familia" '.familias[] | select(.id == $id) | .firmante' "$FAMILIAS/familias.json")"
# shellcheck source=image/instalador/familias/casper.sh
source "$FAMILIAS/$familia.sh"
capas=(); quitar=""; kernel=""; version=""
en_familia familia_sistema
nombre_distro="$(head -n1 "$T/iso/.disk/info" 2>/dev/null | tr -cd 'A-Za-z0-9 ._()"+-' | cut -c1-80)"
echo "Distro: ${nombre_distro:-desconocida}; $nombre_familia; capas: ${#capas[@]}"
serie "familia=$familia"

# Secure Boot: cada familia arranca con el shim y GRUB firmados que le corresponden, y
# esos solo aceptan kernels firmados por su distro (familias.json: "firmante").
sb=0
for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -r "$f" && "$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')" == "1" ]] && sb=1
done
firmante="$(sbverify --list "$kernel" 2>/dev/null | sed -n 's/.*subject: //p' | head -n3 | tr '\n' ' ')"
echo "Kernel firmado por: ${firmante:-nadie}"
if [[ "$firmante" != *"$firmante_esperado"* ]]; then
    if (( sb )); then
        fallar "el kernel de esta ISO no está firmado por $firmante_esperado y no arrancaría con Arranque seguro. Elige una distro del catálogo (no desactives Secure Boot)"
    fi
    echo "Aviso: el kernel no está firmado por $firmante_esperado; solo arrancará sin Arranque seguro."
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
en_familia familia_quitar_vivo

paso "Kernel e initramfs"
en_familia familia_kernel

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

en_familia familia_initramfs

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
