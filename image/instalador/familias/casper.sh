#!/usr/bin/env bash
# casper.sh — Familia Ubuntu (casper): Ubuntu y sabores, Linux Mint, Zorin OS, elementary…
#
# Lo carga instalar-iso.sh (con `source`) cuando la ISO tiene las señales de esta familia
# (ver familias.json). Usa sus variables y funciones: T (montajes; la ISO en $T/iso),
# D (sistema nuevo), en_destino, monta, fallar. Rellena: capas, quitar, kernel, version.
# shellcheck disable=SC2034  # las variables que rellena las usa instalar-iso.sh
set -euo pipefail

# Dónde está el sistema dentro de la ISO.
familia_sistema() {
    capas=()
    quitar=""
    if [[ -f "$T/iso/casper/install-sources.yaml" ]]; then
        # Ubuntu 24.04 y posteriores: sistema en capas (minimal → minimal.standard → …).
        local ruta base prefijo="" p partes
        ruta="$(awk '/^- /{d=0; p=""} /default: true/{d=1} /path:/{p=$2} d && p {print p; exit}' "$T/iso/casper/install-sources.yaml")"
        [[ -n "$ruta" ]] || ruta="$(awk '/path:/{print $2; exit}' "$T/iso/casper/install-sources.yaml")"
        # La ISO es una entrada no confiable: solo un nombre de archivo, sin carpetas.
        [[ "$ruta" =~ ^[A-Za-z0-9._-]+\.squashfs$ ]] || fallar "install-sources.yaml no es válido"
        base="${ruta%.squashfs}"
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
        fallar "la ISO no trae el sistema en casper/"
    fi
    kernel="$(find "$T/iso/casper" -maxdepth 1 -name "vmlinuz*" -type f | sort | head -n1)"
    [[ -f "$kernel" ]] || fallar "la ISO no trae kernel en casper/"
}

# Quita los programas del modo en vivo (instalador, casper…) del sistema nuevo.
familia_quitar_vivo() {
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
}

version_kernel() {
    find "$D/usr/lib/modules/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true
}

# Deja kernel y módulos en el sistema nuevo y fija `version`.
familia_kernel() {
    version="$(version_kernel)"
    if [[ -z "$version" ]]; then
        # Ubuntu 24.04+ instala el kernel aparte, desde los paquetes que trae la propia ISO
        # (carpetas dists/ y pool/). Se hace igual, sin internet.
        echo "El sistema de la ISO no trae kernel: se instala desde los paquetes de la ISO."
        local suite componentes solo_iso meta
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
        if umount -l "$D/media/llevix-iso"; then rmdir "$D/media/llevix-iso" || true; fi
        version="$(version_kernel)"
    fi
    [[ -n "$version" ]] || fallar "la ISO no trae módulos del kernel"
    [[ -f "$D/boot/vmlinuz-$version" ]] || cp "$kernel" "$D/boot/vmlinuz-$version"
    ln -sf "vmlinuz-$version" "$D/boot/vmlinuz"
    ln -sf "initrd.img-$version" "$D/boot/initrd.img"
}

# Initramfs portátil: initramfs-tools usa MODULES=most por defecto (controladores de
# cualquier PC, no solo de esta).
familia_initramfs() {
    if ! en_destino "update-initramfs -c -k $version >/dev/null 2>&1 || update-initramfs -u -k $version"; then
        fallar "no se pudo crear el initramfs"
    fi
    [[ -f "$D/boot/initrd.img-$version" ]] || fallar "no se creó el initramfs"
}
