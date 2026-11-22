#!/usr/bin/env bash
# tools/manifest.sh — Genera manifest.json para un Release de Llevix.
#
# Uso: ./tools/manifest.sh <version> <carpeta-con-archivos> <url-base> > manifest.json
#
# La carpeta debe tener, por cada variante:
#   llevix-<variante>.img.zst               (o sus partes .img.zst.001, .002, …)
#   llevix-<variante>.img.zst.sha256
#   llevix-<variante>.img.bmap
#   llevix-<variante>.img.tamano            (bytes de la imagen sin comprimir)
# Los datos visibles (nombre, ligera, descripción) salen de image/distros/<variante>.conf.
set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 3 ]] || { echo "uso: $0 <version> <carpeta> <url-base>" >&2; exit 2; }
VERSION="$1"; CARPETA="$2"; URL_BASE="${3%/}"

command -v jq >/dev/null || { echo "falta jq" >&2; exit 1; }

variantes="[]"
for conf in "$DIR_REPO"/image/distros/*.conf; do
    id="$(basename "$conf" .conf)"
    zst="$CARPETA/llevix-$id.img.zst"
    # Una variante sin imagen en la carpeta no se publica.
    compgen -G "$zst*" >/dev/null || continue

    # Se leen los datos de la variante en un subshell para no mezclar variables.
    datos="$(
        # shellcheck source=/dev/null
        source "$conf"
        jq -cn --arg id "$id" --arg nombre "$NOMBRE_VISIBLE" --arg desc "${DESCRIPCION:-}" \
            --arg base "$BASE" --arg tipo "${TIPO:-escritorio}" --argjson ligera "$([[ "${LIGERA:-no}" == si ]] && echo true || echo false)" \
            '{id:$id, tipo:$tipo, nombre:$nombre, descripcion:$desc, base:$base, ligera:$ligera}'
    )"

    sha="$(cut -d' ' -f1 "$zst.sha256")"
    tamano_imagen="$(cat "$CARPETA/llevix-$id.img.tamano")"
    bmap="$CARPETA/llevix-$id.img.bmap"

    # Partes: si la imagen se dividió (límite de 2 GiB por archivo en GitHub Releases).
    partes="[]"
    if [[ -f "$zst" ]]; then
        partes="$(jq -cn --arg url "$URL_BASE/llevix-$id.img.zst" --argjson t "$(stat -c %s "$zst")" \
            --arg s "$sha" '[{url:$url, tamano:$t, sha256:$s}]')"
        tamano_zst="$(stat -c %s "$zst")"
    else
        tamano_zst=0
        for parte in "$zst".[0-9][0-9][0-9]; do
            t="$(stat -c %s "$parte")"
            tamano_zst=$((tamano_zst + t))
            partes="$(jq -c --arg url "$URL_BASE/$(basename "$parte")" --argjson t "$t" \
                --arg s "$(sha256sum "$parte" | cut -d' ' -f1)" \
                '. + [{url:$url, tamano:$t, sha256:$s}]' <<<"$partes")"
        done
    fi

    variantes="$(jq -c \
        --argjson d "$datos" --argjson partes "$partes" \
        --argjson tz "$tamano_zst" --argjson ti "$tamano_imagen" --arg sha "$sha" \
        --arg bmap_url "$URL_BASE/$(basename "$bmap")" \
        --arg bmap_sha "$(sha256sum "$bmap" | cut -d' ' -f1)" \
        --arg paquetes_url "$URL_BASE/llevix-$id.paquetes.txt" \
        '. + [$d + {
            tamano_comprimido: $tz,
            tamano_imagen: $ti,
            sha256: $sha,
            partes: $partes,
            bmap_url: $bmap_url,
            bmap_sha256: $bmap_sha,
            paquetes_url: $paquetes_url
        }]' <<<"$variantes")"
done

jq -n --arg v "$VERSION" --arg fecha "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson variantes "$variantes" \
    '{formato: 1, version: $v, fecha: $fecha, variantes: $variantes}'
