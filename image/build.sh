#!/usr/bin/env bash
# build.sh — Construye la imagen de disco de Llevix para una variante de distro.
#
# Uso:   sudo ./image/build.sh <variante>        (ejemplo: ubuntu-24.04)
# Sale:  out/llevix-<variante>.img
#
# Variables opcionales:
#   LLEVIX_OUT        carpeta de salida (por defecto: <repo>/out)
#   LLEVIX_MIRROR     espejo de Ubuntu para descargar (por defecto: archive.ubuntu.com)
#   LLEVIX_IMG_SIZE   tamaño de la imagen (por defecto: 28G)
#   LLEVIX_SYS_SIZE   tamaño de la partición del sistema (por defecto: 24G)
#
# SEGURIDAD: este script solo escribe en un ARCHIVO .img a través de un loop device.
# Nunca toca discos reales; antes de usar un dispositivo comprueba que sea /dev/loopN.

set -euo pipefail

DIR_IMAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_REPO="$(dirname "$DIR_IMAGE")"
OUT_DIR="${LLEVIX_OUT:-$DIR_REPO/out}"
IMG_SIZE="${LLEVIX_IMG_SIZE:-28G}"
SYS_SIZE="${LLEVIX_SYS_SIZE:-24G}"
MIRROR="${LLEVIX_MIRROR:-http://archive.ubuntu.com/ubuntu}"
MIRROR_PUBLICO="http://archive.ubuntu.com/ubuntu"
MIRROR_SEGURIDAD="http://security.ubuntu.com/ubuntu"
COMPONENTES="main,restricted,universe,multiverse"
# Repositorio de Linux Mint y su llave (verificada por SHA256: el servidor no tiene HTTPS).
MINT_REPO="http://packages.linuxmint.com"
MINT_LLAVE_URL="$MINT_REPO/pool/main/l/linuxmint-keyring/linuxmint-keyring_2022.06.21_all.deb"
MINT_LLAVE_SHA256="b71be690c543112ea7b65f43e9bbce9a3f17dd5cc784074858f0824154942a99"
# Repositorio oficial de Mozilla para Firefox en las variantes de Ubuntu (allí Ubuntu solo
# ofrece Firefox como snap, que no se puede instalar al construir la imagen).
MOZILLA_REPO="https://packages.mozilla.org/apt"
MOZILLA_HUELLA="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
OPC_BTRFS="compress=zstd:3,noatime"

LOOP=""
ROOT=""

# ---------- Utilidades ----------

paso()  { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
error() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# Ejecuta un comando dentro del sistema que se está construyendo.
en_chroot() {
    chroot "$ROOT" /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C.UTF-8 \
        bash -euo pipefail -c "$1"
}

# Garantiza que un dispositivo es un loop device y no un disco real.
asegurar_loop() {
    [[ "$1" =~ ^/dev/loop[0-9]+(p[0-9]+)?$ ]] || error "dispositivo inesperado: $1 (solo se permiten loop devices)"
}

limpiar() {
    local codigo=$?
    set +e
    if [[ -n "$ROOT" && -d "$ROOT" ]]; then
        # Desmonta todo lo que quedó montado debajo de ROOT, del más profundo al más alto.
        findmnt -R -n -l -o TARGET "$ROOT" 2>/dev/null | sort -r | while read -r punto; do
            umount "$punto" 2>/dev/null || umount -l "$punto"
        done
        rmdir "$ROOT" 2>/dev/null
    fi
    if [[ -n "$LOOP" ]]; then
        losetup -d "$LOOP"
    fi
    if (( codigo != 0 )); then
        printf '\e[31mLa construcción falló (código %d).\e[0m\n' "$codigo" >&2
    fi
}
trap limpiar EXIT

# ---------- Comprobaciones ----------

VARIANTES="$(for f in "$DIR_IMAGE"/distros/*.conf; do basename "$f" .conf; done | tr '\n' ' ')"
[[ $# -eq 1 ]] || error "uso: sudo $0 <variante>   (variantes: $VARIANTES)"
VARIANTE="$1"
[[ "$VARIANTE" =~ ^[a-z0-9.-]+$ ]] || error "nombre de variante no válido: $VARIANTE"
CONF="$DIR_IMAGE/distros/$VARIANTE.conf"
[[ -f "$CONF" ]] || error "no existe $CONF"
[[ $EUID -eq 0 ]] || error "necesita root: sudo $0 $VARIANTE"

# shellcheck source=/dev/null
source "$CONF"
: "${NOMBRE_VISIBLE:?falta en $CONF}" "${BASE:?}" "${SUITE:?}" "${PAQUETES_ESCRITORIO:?}" "${GESTOR_SESION:?}"
# TIPO: "escritorio" (lo normal) o "instalador" (fase 8: instala una ISO del usuario).
TIPO="${TIPO:-escritorio}"
[[ "$TIPO" != "desde-iso" ]] || error "$VARIANTE se construye desde su ISO: usa image/desde-iso.sh"
[[ "$TIPO" == "escritorio" || "$TIPO" == "instalador" ]] || error "TIPO no válido en $CONF: $TIPO"
# btrfs del instalador: 16 GiB; los 8 GiB finales de la partición guardan la ISO.
FS_INSTALADOR="16G"
# jq oficial (MIT, binario estático): las distros instaladas desde una ISO a veces no lo traen.
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"

for herramienta in debootstrap sgdisk mkfs.vfat mkfs.exfat mkfs.btrfs losetup btrfs fstrim udevadm; do
    command -v "$herramienta" >/dev/null || error "falta $herramienta (ejecuta ./tools/check-env.sh)"
done

if [[ "$BASE" == "debian" ]]; then
    # Debian: sus espejos y sus componentes (con el firmware no libre, como su instalador).
    MIRROR="${LLEVIX_MIRROR_DEBIAN:-http://deb.debian.org/debian}"
    MIRROR_PUBLICO="http://deb.debian.org/debian"
    MIRROR_SEGURIDAD="http://security.debian.org/debian-security"
    COMPONENTES="main,contrib,non-free,non-free-firmware"
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] || error "falta debian-archive-keyring"
    KERNEL="linux-image-amd64 firmware-linux firmware-sof-signed firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 firmware-misc-nonfree"
else
    KERNEL="linux-generic linux-firmware"
fi

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/llevix-$VARIANTE.img"

# ---------- 1. Archivo de imagen y particiones ----------

paso "Creando $IMG ($IMG_SIZE, disperso)"
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"

paso "Creando particiones GPT"
# El orden de creación define la posición física: BIOS boot, ESP y sistema al inicio;
# LLEVIX-DATOS (número 1) ocupa el resto, al final, para poder ampliarla después.
sgdisk --zap-all "$IMG" >/dev/null
sgdisk \
    -n 2:1MiB:+1MiB        -t 2:EF02 -c 2:BIOS-BOOT \
    -n 3:0:+512MiB         -t 3:EF00 -c 3:LLEVIX-EFI \
    -n "4:0:+$SYS_SIZE"    -t 4:8304 -c 4:LLEVIX-SISTEMA \
    -n 1:0:0               -t 1:0700 -c 1:LLEVIX-DATOS \
    "$IMG" >/dev/null
sgdisk -p "$IMG"

LOOP="$(losetup --find --show --partscan "$IMG")"
asegurar_loop "$LOOP"
udevadm settle
for n in 1 2 3 4; do
    for _ in $(seq 20); do [[ -b "${LOOP}p$n" ]] && break; sleep 0.5; done
    [[ -b "${LOOP}p$n" ]] || error "no apareció ${LOOP}p$n"
    asegurar_loop "${LOOP}p$n"
done
P_DATOS="${LOOP}p1"; P_ESP="${LOOP}p3"; P_SIS="${LOOP}p4"

paso "Formateando"
mkfs.exfat -L LLEVIX "$P_DATOS" >/dev/null
mkfs.vfat -F 32 -n LLEVIX-EFI "$P_ESP" >/dev/null
if [[ "$TIPO" == "instalador" ]]; then
    mkfs.btrfs -f -q -L LLEVIX-SISTEMA --byte-count "$FS_INSTALADOR" "$P_SIS"
else
    mkfs.btrfs -f -q -L LLEVIX-SISTEMA "$P_SIS"
fi
udevadm settle

UUID_SIS="$(blkid -s UUID -o value "$P_SIS")"
UUID_ESP="$(blkid -s UUID -o value "$P_ESP")"
[[ -n "$UUID_SIS" && -n "$UUID_ESP" ]] || error "no se pudieron leer los UUID"

# ---------- 2. Subvolúmenes y montaje ----------

paso "Creando subvolúmenes btrfs @, @home y @snapshots"
ROOT="$(mktemp -d /tmp/llevix-root.XXXXXX)"
mount "$P_SIS" "$ROOT"
btrfs -q subvolume create "$ROOT/@"
btrfs -q subvolume create "$ROOT/@home"
# @snapshots guarda los "estados" del sistema (ver overlay/usr/lib/llevix/guardar-estado.sh).
btrfs -q subvolume create "$ROOT/@snapshots"
umount "$ROOT"

mount -o "subvol=@,$OPC_BTRFS" "$P_SIS" "$ROOT"
mkdir -p "$ROOT/home" "$ROOT/boot/efi"
mount -o "subvol=@home,$OPC_BTRFS" "$P_SIS" "$ROOT/home"
mount "$P_ESP" "$ROOT/boot/efi"

# ---------- 3. Sistema base ----------

paso "debootstrap $SUITE (esto tarda unos minutos)"
LLAVERO=()
[[ "$BASE" == "debian" ]] && LLAVERO=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
# Hasta 3 intentos: a veces el mirror corta la descarga de un paquete ("Couldn't
# download packages"). El reintento aprovecha lo ya descargado en $ROOT.
for intento in 1 2 3; do
    if debootstrap --arch=amd64 --components="$COMPONENTES" "${LLAVERO[@]}" \
        "$SUITE" "$ROOT" "$MIRROR"; then
        break
    fi
    (( intento < 3 )) || error "debootstrap falló 3 veces"
    echo "debootstrap falló (intento $intento); se reintenta en 30 s" >&2
    sleep 30
done

mkdir -p "$ROOT/.snapshots"
mount --bind /dev "$ROOT/dev"
mount -t devpts devpts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount -t tmpfs tmpfs "$ROOT/run"

# DNS durante la construcción: copia del servidor real del equipo que construye.
poner_dns() {
    rm -f "$ROOT/etc/resolv.conf"
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        cp /run/systemd/resolve/resolv.conf "$ROOT/etc/resolv.conf"
    else
        cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
    fi
}
poner_dns

# Fuentes de apt. En Ubuntu: formato deb822 (ubuntu.sources). En Mint, una vez instalada
# su llave: el archivo y formato que usa Linux Mint (official-package-repositories.list);
# si no, su Gestor de actualizaciones dice que la configuración de APT está corrupta.
escribir_fuentes() {
    rm -f "$ROOT/etc/apt/sources.list"
    if [[ "$BASE" == "mint" && -f "$ROOT/etc/apt/trusted.gpg.d/linuxmint-keyring.gpg" ]]; then
        rm -f "$ROOT/etc/apt/sources.list.d/ubuntu.sources" "$ROOT/etc/apt/sources.list.d/linuxmint.sources"
        : > "$ROOT/etc/apt/sources.list"
        cat > "$ROOT/etc/apt/sources.list.d/official-package-repositories.list" <<EOF
deb $MINT_REPO $MINT_SUITE main upstream import backport

deb $1 $SUITE main restricted universe multiverse
deb $1 $SUITE-updates main restricted universe multiverse
deb $1 $SUITE-backports main restricted universe multiverse

deb $2 $SUITE-security main restricted universe multiverse
EOF
        return 0
    fi
    if [[ "$BASE" == "debian" ]]; then
        cat > "$ROOT/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $1
Suites: $SUITE $SUITE-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $2
Suites: $SUITE-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        return 0
    fi
    cat > "$ROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $1
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $2
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
}
escribir_fuentes "$MIRROR" "$MIRROR_SEGURIDAD"

if [[ "$BASE" == "mint" ]]; then
    : "${MINT_SUITE:?falta MINT_SUITE en $CONF}"
    paso "Agregando el repositorio de Linux Mint ($MINT_SUITE)"
    curl -fsSL --retry 3 -o "$ROOT/tmp/linuxmint-keyring.deb" "$MINT_LLAVE_URL"
    echo "$MINT_LLAVE_SHA256  $ROOT/tmp/linuxmint-keyring.deb" | sha256sum -c -         || error "la llave de Linux Mint no coincide con la suma SHA256 esperada"
    # La llave necesita gnupg instalado antes. El paquete trae dos llaveros: el
    # vigente es el de /etc/apt/trusted.gpg.d (el de /usr/share/keyrings es de 2016).
    en_chroot "apt-get update && apt-get -y install gnupg && dpkg -i /tmp/linuxmint-keyring.deb && rm /tmp/linuxmint-keyring.deb"
    escribir_fuentes "$MIRROR" "$MIRROR_SEGURIDAD"
    # Las mismas prioridades que trae Linux Mint.
    cat > "$ROOT/etc/apt/preferences.d/official-package-repositories.pref" <<'EOF'
Package: *
Pin: origin live.linuxmint.com
Pin-Priority: 750

Package: *
Pin: release o=linuxmint,c=upstream
Pin-Priority: 700

Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 200
EOF
fi

if [[ "$BASE" == "ubuntu" && "$TIPO" == "escritorio" ]]; then
    paso "Agregando el repositorio oficial de Mozilla (Firefox)"
    mkdir -p "$ROOT/etc/apt/keyrings"
    curl -fsSL --retry 3 -o "$ROOT/etc/apt/keyrings/packages.mozilla.org.asc" "$MOZILLA_REPO/repo-signing-key.gpg"
    huella="$(GNUPGHOME="$(mktemp -d)" gpg --show-keys --with-colons \
        "$ROOT/etc/apt/keyrings/packages.mozilla.org.asc" | awk -F: '$1 == "fpr" {print $10; exit}')"
    [[ "$huella" == "$MOZILLA_HUELLA" ]] || error "la llave de Mozilla no tiene la huella esperada ($huella)"
    cat > "$ROOT/etc/apt/sources.list.d/mozilla.sources" <<EOF
Types: deb
URIs: $MOZILLA_REPO
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
    # Firefox de Mozilla por encima del paquete de Ubuntu (que solo instala el snap).
    cat > "$ROOT/etc/apt/preferences.d/mozilla" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
fi

# Durante la construcción, apt reintenta las descargas (los espejos a veces fallan).
echo 'Acquire::Retries "5";' > "$ROOT/etc/apt/apt.conf.d/80llevix-reintentos"

# Durante la construcción no se arranca ningún servicio.
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod +x "$ROOT/usr/sbin/policy-rc.d"

# Thunderbird de Ubuntu 24.04 es un paquete que instala un snap, y eso no funciona
# dentro de un chroot: se excluye. Firefox viene del repositorio de Mozilla.
if [[ "$BASE" == "ubuntu" ]]; then
    cat > "$ROOT/etc/apt/preferences.d/llevix-sin-snaps-transicionales" <<'EOF'
Package: thunderbird
Pin: version *
Pin-Priority: -1
EOF
fi

# Respuestas automáticas para GRUB: no instalar en ningún disco ni tocar la NVRAM.
en_chroot "debconf-set-selections <<'EOF'
grub-pc grub-pc/install_devices multiselect
grub-pc grub-pc/install_devices_empty boolean true
grub-efi-amd64 grub2/update_nvram boolean false
grub-efi-amd64-signed grub2/update_nvram boolean false
EOF"

# Configuración de GRUB propia de Llevix (antes de instalar el kernel).
mkdir -p "$ROOT/etc/default/grub.d"
cat > "$ROOT/etc/default/grub.d/llevix.cfg" <<'EOF'
# Ajustes de Llevix.
GRUB_DISTRIBUTOR="Llevix"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
# Nunca buscar otros sistemas: en un disco portátil no tiene sentido y además
# examinaría los discos de la PC donde se construye.
GRUB_DISABLE_OS_PROBER=true
EOF

paso "Instalando kernel, firmware y cargadores de arranque"
en_chroot "apt-get update && apt-get -y full-upgrade"
if [[ "$BASE" == "debian" ]]; then
    # Como en Ubuntu: enlaces /boot/vmlinuz e /boot/initrd.img al kernel actual (los usan
    # el modo gráficos seguros y los estados guardados).
    printf 'do_symlinks = yes\nlink_in_boot = yes\n' > "$ROOT/etc/kernel-img.conf"
fi
en_chroot "apt-get -y install $KERNEL \
    btrfs-progs exfatprogs dosfstools \
    shim-signed grub-efi-amd64-signed grub-efi-amd64-bin grub-pc-bin grub2-common \
    sudo locales tzdata jq gdisk qemu-guest-agent sg3-utils hdparm"

poner_dns
LISTA="$DIR_IMAGE/distros/paquetes/$VARIANTE.txt"
if [[ -f "$LISTA" ]]; then
    # La misma lista de paquetes que instala la ISO oficial (tools/manifiesto-iso.sh).
    # Se quitan los que ya no existen en el repositorio y se anotan.
    paso "Instalando escritorio: los $(wc -l < "$LISTA") paquetes de la ISO oficial"
    en_chroot "apt-cache pkgnames | sort -u" > "$ROOT/tmp/disponibles"
    LC_ALL=C sort -u "$LISTA" | LC_ALL=C comm -12 - "$ROOT/tmp/disponibles" > "$ROOT/tmp/lista"
    faltan_lista="$(LC_ALL=C sort -u "$LISTA" | LC_ALL=C comm -23 - "$ROOT/tmp/disponibles" | tr '\n' ' ')"
    [[ -z "$faltan_lista" ]] || echo "Aviso: ya no están en el repositorio: $faltan_lista"
    en_chroot "xargs -a /tmp/lista apt-get -y install"
    # Los que no aparecieron en el índice se intentan uno por uno (algunos son nombres
    # virtuales o ya vienen como dependencia); los que de verdad no existen se ignoran.
    for p in $faltan_lista; do
        if en_chroot "apt-get -y install $p >/dev/null 2>&1"; then
            echo "  instalado igual: $p"
        fi
    done
    rm -f "$ROOT/tmp/lista" "$ROOT/tmp/disponibles"
else
    paso "Instalando escritorio: $PAQUETES_ESCRITORIO"
    # shellcheck disable=SC2086  # la lista de paquetes se separa a propósito
    en_chroot "apt-get -y install $PAQUETES_ESCRITORIO"
fi
if [[ "$TIPO" == "escritorio" ]]; then
NAVEGADOR=""
[[ "$BASE" == "ubuntu" ]] && NAVEGADOR="firefox firefox-l10n-es-es firefox-l10n-es-mx firefox-l10n-es-ar"
[[ "$BASE" == "debian" ]] && NAVEGADOR="firefox-esr firefox-esr-l10n-es-es firefox-esr-l10n-es-mx firefox-esr-l10n-es-ar"
en_chroot "apt-get -y install ${PAQUETES_IDIOMA:-} $NAVEGADOR"

# Lo que cualquier usuario necesita desde el primer minuto. Si falta algo, la
# construcción falla (así no se publica una imagen sin red, sonido o navegador).
paso "Comprobando que el escritorio está completo"
en_chroot "$(cat "$DIR_IMAGE/lib/verificar-escritorio.sh")"

if [[ "$BASE" == "ubuntu" && "$GESTOR_SESION" == "gdm3" ]]; then
    # El panel de Ubuntu apunta al Firefox snap (firefox_firefox.desktop): se apunta al de Mozilla.
    cat > "$ROOT/usr/share/glib-2.0/schemas/90_llevix.gschema.override" <<'EOF'
[org.gnome.shell:ubuntu]
favorite-apps = ['firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Software.desktop', 'yelp.desktop']
EOF
    en_chroot "glib-compile-schemas /usr/share/glib-2.0/schemas"
fi
fi   # TIPO == escritorio

# ---------- 4. Configuración del sistema ----------

paso "Configurando el sistema"

cat > "$ROOT/etc/fstab" <<EOF
# Llevix: todo por UUID, nunca por /dev/sdX (el disco cambia de nombre en cada PC).
UUID=$UUID_SIS  /          btrfs  subvol=@,$OPC_BTRFS      0  0
UUID=$UUID_SIS  /home      btrfs  subvol=@home,$OPC_BTRFS  0  0
UUID=$UUID_SIS  /.snapshots btrfs subvol=@snapshots,$OPC_BTRFS 0  0
UUID=$UUID_ESP  /boot/efi  vfat   umask=0077,nofail        0  1
EOF

echo "llevix" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   llevix
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Red: NetworkManager maneja todas las interfaces.
if [[ "$BASE" != "debian" ]]; then
    mkdir -p "$ROOT/etc/netplan"
    cat > "$ROOT/etc/netplan/01-network-manager-all.yaml" <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
    chmod 600 "$ROOT/etc/netplan/01-network-manager-all.yaml"
fi
# Ninguna conexión guardada atada a una tarjeta de red concreta.
rm -f "$ROOT"/etc/NetworkManager/system-connections/*

if [[ "$BASE" == "debian" ]]; then
    # En Debian, locale-gen genera lo que está activo en /etc/locale.gen.
    printf '%s\n' "en_US.UTF-8 UTF-8" "es_ES.UTF-8 UTF-8" >> "$ROOT/etc/locale.gen"
    en_chroot "locale-gen >/dev/null && update-locale LANG=C.UTF-8"
else
    en_chroot "locale-gen C.UTF-8 en_US.UTF-8 es_ES.UTF-8 >/dev/null && update-locale LANG=C.UTF-8"
fi

# Archivos propios de Llevix (servicios, scripts).
paso "Copiando la capa de Llevix (image/overlay)"
cp -a "$DIR_IMAGE/overlay/." "$ROOT/"
find "$ROOT" -xdev -name .gitkeep -delete

# Primer arranque: lee llevix-config.json, crea el usuario y amplía LLEVIX-DATOS.
install -D -m 0755 "$DIR_IMAGE/firstboot/firstboot.sh" "$ROOT/usr/lib/llevix/firstboot.sh"
install -D -m 0644 "$DIR_IMAGE/firstboot/llevix-firstboot.service" \
    "$ROOT/usr/lib/systemd/system/llevix-firstboot.service"
install -D -m 0644 "$DIR_REPO/docs/llevix-config.md" "$ROOT/usr/share/doc/llevix/llevix-config.md"
# Reporte de diagnóstico para la beta (docs/BETA.md): sudo /usr/lib/llevix/report.sh
install -D -m 0755 "$DIR_REPO/tools/report.sh" "$ROOT/usr/lib/llevix/report.sh"

if [[ "$TIPO" == "instalador" ]]; then
    paso "Instalador de ISO y capa de Llevix para el sistema que se instale"
    install -D -m 0755 "$DIR_IMAGE/instalador/instalar-iso.sh" "$ROOT/usr/lib/llevix/instalar-iso.sh"
    install -D -m 0644 "$DIR_IMAGE/instalador/llevix-instalar-iso.service" \
        "$ROOT/usr/lib/systemd/system/llevix-instalar-iso.service"
    CAPA="$ROOT/usr/share/llevix/capa"
    mkdir -p "$CAPA"
    cp -a "$DIR_IMAGE/overlay" "$CAPA/overlay"
    find "$CAPA" -name .gitkeep -delete
    install -m 0755 "$DIR_IMAGE/firstboot/firstboot.sh" "$CAPA/firstboot.sh"
    install -m 0644 "$DIR_IMAGE/firstboot/llevix-firstboot.service" "$CAPA/llevix-firstboot.service"
    install -m 0755 "$DIR_REPO/tools/report.sh" "$CAPA/report.sh"
    install -m 0644 "$DIR_REPO/docs/llevix-config.md" "$CAPA/llevix-config.md"
    curl -fsSL --retry 3 -o "$CAPA/jq" "$JQ_URL"
    echo "$JQ_SHA256  $CAPA/jq" | sha256sum -c - || error "jq no coincide con su SHA256"
    chmod 0755 "$CAPA/jq"
    # El instalador no tiene escritorio ni crea cuentas: solo instala la ISO.
    en_chroot "systemctl enable llevix-instalar-iso.service llevix-disco-sistema.service tmp.mount \
        && systemctl set-default multi-user.target"
else
    en_chroot "systemctl enable llevix-estado-arranque.service llevix-firstboot.service \
        llevix-disco-sistema.service fstrim.timer tmp.mount"
fi

mkdir -p "$ROOT/etc/llevix"
cat > "$ROOT/etc/llevix/version" <<EOF
VARIANTE=$VARIANTE
NOMBRE="$NOMBRE_VISIBLE"
FECHA=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git -C "$DIR_REPO" rev-parse --short HEAD 2>/dev/null || echo desconocido)
EOF

# ---------- 5. Usuarios ----------
# La imagen no trae ninguna cuenta de usuario: la crea llevix-firstboot a partir de
# llevix-config.json, o la pantalla de bienvenida de la distro si no hay archivo.

# ---------- 6. Marca ----------

paso "Marca: Llevix, basado en $BASE"
# Nombre del sistema. Se desvía el archivo del paquete para que una actualización no
# lo pise; ID sigue siendo "ubuntu" para que los programas sepan qué base es.
en_chroot "dpkg-divert --quiet --local --rename --add /usr/lib/os-release"
sed -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"$NOMBRE_VISIBLE\"/" \
    "$ROOT/usr/lib/os-release.distrib" > "$ROOT/usr/lib/os-release"

# Logo de Ubuntu en la pantalla de arranque: se reemplaza por una imagen transparente.
PNG_VACIO='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
for logo in /usr/share/plymouth/ubuntu-logo.png /usr/share/plymouth/themes/spinner/watermark.png; do
    if [[ -f "$ROOT$logo" ]]; then
        en_chroot "dpkg-divert --quiet --local --rename --add $logo"
        printf '%s' "$PNG_VACIO" | base64 -d > "$ROOT$logo"
    fi
done

# ---------- 7. Cargadores de arranque ----------

paso "Instalando GRUB (UEFI con Secure Boot y BIOS)"
en_chroot "update-initramfs -u -k all"

# UEFI: modo "removable" (EFI/BOOT/BOOTX64.EFI = shim firmado). Así arranca en
# cualquier PC sin registrar nada en la NVRAM.
en_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --uefi-secure-boot --removable --no-nvram"

# El GRUB firmado de Ubuntu busca su grub.cfg en varios lugares según cómo arrancó
# (EFI/ubuntu, junto a sí mismo o /boot/grub de la partición EFI). Se deja el mismo
# archivo puente en los tres: busca la partición del sistema por UUID y carga el
# grub.cfg real que está en el subvolumen @.
for d in EFI/BOOT EFI/ubuntu EFI/debian boot/grub; do
    mkdir -p "$ROOT/boot/efi/$d"
    cat > "$ROOT/boot/efi/$d/grub.cfg" <<EOF
echo "Llevix: buscando el sistema..."
if search --no-floppy --fs-uuid --set=root $UUID_SIS; then
    set prefix=(\$root)'/@/boot/grub'
    configfile \$prefix/grub.cfg
else
    echo "Llevix: no se encontró la partición del sistema ($UUID_SIS)."
fi
EOF
done

# BIOS: GRUB en la partición BIOS boot del archivo de imagen (loop device).
asegurar_loop "$LOOP"
en_chroot "grub-install --target=i386-pc --modules='part_gpt btrfs' $LOOP"

en_chroot "update-grub"
grep -q "root=UUID=$UUID_SIS" "$ROOT/boot/grub/grub.cfg" \
    || error "grub.cfg no usa root=UUID=$UUID_SIS"
grep -q "rootflags=subvol=@" "$ROOT/boot/grub/grub.cfg" \
    || error "grub.cfg no indica el subvolumen @"

# ---------- 8. Limpieza ----------

# Lista exacta de paquetes y versiones (para el Release y el cumplimiento de la GPL:
# con esto se puede obtener el código fuente de cada paquete).
paso "Guardando la lista de paquetes"
en_chroot "dpkg-query -W -f='\${Package}\t\${Version}\t\${source:Package}\t\${source:Version}\n'" \
    | sort > "$OUT_DIR/llevix-$VARIANTE.paquetes.txt"
wc -l < "$OUT_DIR/llevix-$VARIANTE.paquetes.txt"

paso "Limpiando"
escribir_fuentes "$MIRROR_PUBLICO" "$MIRROR_SEGURIDAD"
rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/etc/apt/apt.conf.d/80llevix-reintentos"
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
# machine-id vacío: cada PC/arranque genera el suyo la primera vez.
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/dbus/machine-id"
ln -sf /etc/machine-id "$ROOT/var/lib/dbus/machine-id"
if [[ -e "$ROOT/usr/lib/systemd/systemd-resolved" || -e "$ROOT/lib/systemd/systemd-resolved" ]]; then
    ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
else
    # Sin systemd-resolved (Debian): NetworkManager escribe /etc/resolv.conf directamente.
    rm -f "$ROOT/etc/resolv.conf"
    : > "$ROOT/etc/resolv.conf"
fi

df -h "$ROOT" "$ROOT/boot/efi"
# fstrim libera en el archivo los bloques vacíos: la imagen ocupa solo lo que usa.
for punto in "$ROOT/boot/efi" "$ROOT"; do
    fstrim -v "$punto" || true
done

sync
paso "Listo: $IMG"
du -h --apparent-size "$IMG"
du -h "$IMG"
