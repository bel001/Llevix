#!/usr/bin/env bash
# live-boot.sh — Familia Debian (live-boot): ISOs "live" de Debian.
#
# Lo carga instalar-iso.sh (con `source`) cuando la ISO tiene las señales de esta familia
# (ver familias.json). Usa sus variables y funciones: T (montajes; la ISO en $T/iso),
# D (sistema nuevo), en_destino, monta, fallar. Rellena: capas, quitar, kernel, version.
#
# Lo que trae una ISO live de Debian 13 (comprobado con sus listas publicadas
# debian-live-*.iso.contents y .packages):
# - el sistema en live/filesystem.squashfs y el kernel firmado por Debian en live/vmlinuz-*;
# - el sistema NO trae el arranque firmado (shim-signed, grub-efi-amd64-signed), pero la
#   ISO sí los trae en pool/ con su índice en dists/: se instalan desde ahí, sin internet.
# shellcheck disable=SC2034  # las variables que rellena las usa instalar-iso.sh
set -euo pipefail

# Paquetes del arranque firmado de Debian (los mismos que usa build.sh para las variantes
# Debian del catálogo). Sin grub-efi-amd64: su postinst intentaría registrar el arranque
# en la NVRAM de la PC.
PAQUETES_ARRANQUE_DEBIAN="shim-signed grub-efi-amd64-signed grub-efi-amd64-bin grub-pc-bin grub2-common"

# Dónde está el sistema dentro de la ISO.
familia_sistema() {
    capas=("$T/iso/live/filesystem.squashfs")
    [[ -f "${capas[0]}" ]] || fallar "la ISO no trae el sistema en live/filesystem.squashfs"
    quitar=""
    [[ -f "$T/iso/live/filesystem.packages-remove" ]] && quitar="$T/iso/live/filesystem.packages-remove"
    kernel="$(find "$T/iso/live" -maxdepth 1 -name "vmlinuz*" -type f | sort -V | tail -n1)"
    [[ -f "$kernel" ]] || fallar "la ISO no trae kernel en live/"
}

# Instala paquetes en el sistema nuevo desde pool/ y dists/ de la propia ISO (sin internet).
desde_la_iso() {
    local suite componentes solo_iso
    suite="$(find "$T/iso/dists" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1)"
    [[ -n "$suite" && -d "$T/iso/pool" ]] || fallar "la ISO no trae paquetes (dists/ y pool/)"
    mkdir -p "$D/media/llevix-iso"
    monta "$T/iso" "$D/media/llevix-iso" --bind
    componentes="$(find "$T/iso/dists/$suite" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
    echo "deb [trusted=yes] file:///media/llevix-iso $suite ${componentes:-main}" > "$D/tmp/llevix-iso.list"
    solo_iso="-o Dir::Etc::sourcelist=/tmp/llevix-iso.list -o Dir::Etc::sourceparts=/nonexistent -o APT::Get::List-Cleanup=0"
    en_destino "apt-get $solo_iso update" || fallar "no se pudieron leer los paquetes de la ISO"
    echo "Instalando desde la ISO: $*"
    en_destino "apt-get $solo_iso -y --no-install-recommends install $*" || fallar "no se pudo instalar desde la ISO: $*"
    rm -f "$D/tmp/llevix-iso.list"
    # Las listas de la ISO no sirven después: el sistema usa su sources.list normal.
    rm -rf "$D/var/lib/apt/lists/"*_media_llevix-iso_* 2>/dev/null || true
    if umount -l "$D/media/llevix-iso"; then rmdir "$D/media/llevix-iso" || true; fi
}

# Quita los programas del modo en vivo (live-boot, live-config, el instalador Calamares…).
familia_quitar_vivo() {
    {
        [[ -n "$quitar" ]] && awk '{print $1}' "$quitar" | sed 's/:.*$//'
        printf '%s\n' live-boot live-boot-doc live-boot-initramfs-tools live-config live-config-doc \
            live-config-systemd live-config-sysvinit live-tools calamares calamares-settings-debian \
            debian-installer-launcher
        # Metapaquetes del modo en vivo (no traen programas: solo dependencias).
        en_destino "dpkg-query -W -f='\${Package}\n'" | grep '^live-task-' || true
    } | sort -u > "$D/tmp/quitar"
    # shellcheck disable=SC2016  # se expande dentro del chroot
    en_destino 'instalados="$(dpkg-query -W -f="\${Package}\n" | sort -u)"
        lista="$(sort -u /tmp/quitar | comm -12 - <(echo "$instalados") | tr "\n" " ")"
        if [ -n "$lista" ]; then
            apt-get -y purge $lista >/dev/null 2>&1 || for p in $lista; do apt-get -y purge "$p" >/dev/null 2>&1 || true; done
        fi
        rm -f /tmp/quitar'
}

version_kernel() {
    find "$D/usr/lib/modules/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true
}

# Kernel y módulos (ya vienen en el sistema de la ISO) y el arranque firmado de Debian.
familia_kernel() {
    version="$(version_kernel)"
    [[ -n "$version" ]] || fallar "la ISO no trae módulos del kernel"
    [[ -f "$D/boot/vmlinuz-$version" ]] || cp "$kernel" "$D/boot/vmlinuz-$version"
    ln -sf "vmlinuz-$version" "$D/boot/vmlinuz"
    ln -sf "initrd.img-$version" "$D/boot/initrd.img"
    # shellcheck disable=SC2086  # lista de paquetes separada por espacios
    desde_la_iso $PAQUETES_ARRANQUE_DEBIAN
}

# Initramfs portátil: initramfs-tools usa MODULES=most por defecto (controladores de
# cualquier PC, no solo de esta).
familia_initramfs() {
    if ! en_destino "update-initramfs -c -k $version >/dev/null 2>&1 || update-initramfs -u -k $version"; then
        fallar "no se pudo crear el initramfs"
    fi
    [[ -f "$D/boot/initrd.img-$version" ]] || fallar "no se creó el initramfs"
}

# UEFI con Secure Boot: el shim y el GRUB firmados de Debian reemplazan a los del
# instalador (que son de Ubuntu y solo aceptan kernels de Canonical). Modo "removable"
# (EFI/BOOT/BOOTX64.EFI), sin tocar la NVRAM de la PC. Se ejecuta con el sistema nuevo
# ya montado como @ (grub-install calcula la ruta /@/boot/grub).
familia_arranque() {
    en_destino "grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --uefi-secure-boot --removable --no-nvram" || fallar "no se pudo instalar el arranque firmado de Debian"
    [[ -f /boot/efi/EFI/BOOT/BOOTX64.EFI && -f /boot/efi/EFI/BOOT/grubx64.efi ]] \
        || fallar "falta el arranque firmado de Debian en la partición EFI"
    local firma
    firma="$(sbverify --list /boot/efi/EFI/BOOT/grubx64.efi 2>/dev/null | sed -n 's/.*subject: //p' | tr '\n' ' ')"
    echo "GRUB firmado por: ${firma:-nadie}"
    [[ "$firma" == *Debian* ]] || fallar "el GRUB instalado no está firmado por Debian"
}
