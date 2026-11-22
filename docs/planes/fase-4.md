# Plan — Fase 4: publicación automática

## Flujo (`.github/workflows/release.yml`, al hacer push de una etiqueta `v*`)
1. `imagenes`: reutiliza `build.yml` (`workflow_call`): construye las 7 variantes y corre
   todas las pruebas de QEMU. Cada variante deja como artefacto: `.img.zst`, su `.sha256`,
   `.img.bmap` (`bmaptool create`), `.img.tamano` y `.paquetes.txt`.
2. `publicar`: descarga los artefactos, divide en partes `.001`, `.002`… los archivos de
   2 GiB o más (límite de GitHub Releases por archivo), genera `manifest.json`
   (`tools/manifest.sh`) y notas en español, y crea el Release con `gh release create`.
   Las etiquetas con guion (por ejemplo `v0.0.1-test`) se publican como "pre-release".

## manifest.json
`formato`, `version`, `fecha` y por variante: `id`, `nombre`, `descripcion`, `base`,
`ligera`, `tamano_comprimido`, `tamano_imagen`, `sha256` (de la imagen comprimida
completa), `partes` (url, tamaño, sha256 de cada parte), `bmap_url`, `bmap_sha256`,
`paquetes_url`. Es el formato que lee el creador (`creator/nucleo/src/manifest.rs`).

## Licencias (GPL)
- `build.sh` guarda la lista exacta de paquetes y versiones (paquete, versión, paquete
  fuente, versión fuente) en `llevix-<variante>.paquetes.txt`, publicada en el Release.
- Las notas enlazan al código fuente: Launchpad / `apt-get source` / snapshot.ubuntu.com,
  el pool de Linux Mint y el código de Llevix en la etiqueta publicada.

## Tamaño de los archivos
Las imágenes comprimidas pesan ~3,6 GB: se dividen en partes de 1900 MiB. El creador
descarga las partes y las lee en cadena sin unirlas. Para Rufus/Etcher, las notas
explican cómo unirlas. No hace falta otro alojamiento.

## Prueba
Etiqueta `v0.0.1-test` → comprobar que el Release tiene, para cada variante, imagen
(o partes), `.sha256`, `.bmap`, `.paquetes.txt`, y un `manifest.json` válido con las 7.
