#!/usr/bin/env bash
# make-config.sh — Genera un llevix-config.json de PRUEBA (formato en docs/llevix-config.md).
#
# Uso:
#   ./tools/make-config.sh --usuario ana [opciones] > llevix-config.json
#
# Opciones:
#   --usuario NOMBRE          nombre de la cuenta (obligatorio)
#   --nombre-completo TEXTO   nombre para mostrar
#   --contrasena TEXTO        contraseña; si no se da, se pide por teclado
#   --idioma LOCALE           por defecto es_ES.UTF-8
#   --zona ZONA               por defecto UTC
#   --teclado DIST            por defecto es
#   --variante-teclado VAR    por defecto vacío
#   --hostname NOMBRE         por defecto llevix
#   --hash HASH               usar este hash tal cual (para pruebas de errores)
#
# La contraseña nunca se escribe: solo su hash SHA-512 ($6$...).

set -euo pipefail

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || error "falta jq"
command -v openssl >/dev/null || error "falta openssl"

usuario=""; nombre_completo=""; contrasena=""; hash=""
idioma="es_ES.UTF-8"; zona="UTC"; teclado="es"; variante=""; nombre_equipo="llevix"
tiene_contrasena=0

while (( $# > 0 )); do
    case "$1" in
        --usuario)          usuario="${2:?}"; shift 2 ;;
        --nombre-completo)  nombre_completo="${2:?}"; shift 2 ;;
        --contrasena)       contrasena="${2:?}"; tiene_contrasena=1; shift 2 ;;
        --idioma)           idioma="${2:?}"; shift 2 ;;
        --zona)             zona="${2:?}"; shift 2 ;;
        --teclado)          teclado="${2:?}"; shift 2 ;;
        --variante-teclado) variante="${2-}"; shift 2 ;;
        --hostname)         nombre_equipo="${2:?}"; shift 2 ;;
        --hash)             hash="${2:?}"; shift 2 ;;
        -h|--help)          sed -n '2,20p' "$0"; exit 0 ;;
        *) error "opción desconocida: $1" ;;
    esac
done

[[ -n "$usuario" ]] || error "falta --usuario"

if [[ -z "$hash" ]]; then
    if (( ! tiene_contrasena )); then
        read -r -s -p "Contraseña para $usuario: " contrasena; echo >&2
        read -r -s -p "Repítela: " otra; echo >&2
        [[ "$contrasena" == "$otra" ]] || error "las contraseñas no coinciden"
    fi
    [[ -n "$contrasena" ]] || error "la contraseña no puede estar vacía"
    hash="$(printf '%s' "$contrasena" | openssl passwd -6 -stdin)"
    unset contrasena
fi

jq -n \
    --arg usuario "$usuario" \
    --arg nombre_completo "$nombre_completo" \
    --arg hash "$hash" \
    --arg idioma "$idioma" \
    --arg zona "$zona" \
    --arg teclado "$teclado" \
    --arg variante "$variante" \
    --arg hostname "$nombre_equipo" \
    '{
        version: 1,
        usuario: { nombre: $usuario, nombre_completo: $nombre_completo, hash_contrasena: $hash },
        idioma: $idioma,
        zona_horaria: $zona,
        teclado: { distribucion: $teclado, variante: $variante },
        hostname: $hostname,
        accesibilidad: { lector_pantalla: false, texto_grande: false }
    }'
