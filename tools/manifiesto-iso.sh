#!/usr/bin/env bash
# manifiesto-iso.sh — Lista de paquetes que instala una distro desde su ISO oficial.
#
# Uso: ./tools/manifiesto-iso.sh <archivo.iso> > image/distros/paquetes/<variante>.txt
#
# Lee casper/filesystem.manifest (todo lo que trae el sistema en vivo) y le quita
# casper/filesystem.manifest-remove (lo que el instalador borra al terminar), sin montar
# nada. Además quita lo que Llevix maneja por su cuenta: kernel y módulos de una versión
# fija, cargadores de arranque y paquetes del modo en vivo.
# El resultado son solo nombres de paquetes, uno por línea, ordenados.

set -euo pipefail

[[ $# -eq 1 && -f "$1" ]] || { echo "uso: $0 <archivo.iso>" >&2; exit 2; }
command -v bsdtar >/dev/null || { echo "falta bsdtar (paquete libarchive-tools)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bsdtar -x -f "$1" -C "$tmp" casper/filesystem.manifest
bsdtar -x -f "$1" -C "$tmp" casper/filesystem.manifest-remove 2>/dev/null || touch "$tmp/casper/filesystem.manifest-remove"

# Nombres de paquete sin arquitectura (paquete:amd64 → paquete).
nombres() { awk '{print $1}' "$1" | sed 's/:.*$//' | sort -u; }
nombres "$tmp/casper/filesystem.manifest" > "$tmp/todo"
nombres "$tmp/casper/filesystem.manifest-remove" > "$tmp/quitar"

echo "Paquetes en la ISO: $(wc -l < "$tmp/todo"); los quita el instalador: $(wc -l < "$tmp/quitar")" >&2

comm -23 "$tmp/todo" "$tmp/quitar" | grep -Ev \
    -e '^linux-(image|headers|modules|modules-extra|hwe|tools|cloud-tools|objects|signatures|buildinfo)-' \
    -e '^linux-(generic|signed|headers-generic|image-generic|tools-common)' \
    -e '^(grub|shim|efibootmgr|mokutil|os-prober)' \
    -e '^(casper|lupin-casper|ubiquity|live-installer|live-boot|live-config|calamares|oem-config)' \
    -e '^(user-setup|localechooser-data|cifs-utils|squashfs-tools)$' \
    -e '^(nvidia|libnvidia|xserver-xorg-video-nvidia)'
