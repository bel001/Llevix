# creator/ — Creador de Llevix para Windows

App de escritorio (Tauri 2 + Svelte 5) que prepara una memoria USB o un disco externo
con Llevix en 3 pasos: elegir el sistema, escribir la cuenta y elegir el disco.

## Partes

| Carpeta | Qué es |
| --- | --- |
| `nucleo/` | Lógica en Rust sin interfaz: manifest, descarga, bmap, escritura, GPT/ESP, config, filtro de discos y acceso a discos de Windows. Se prueba con `cargo test`. |
| `src-tauri/` | La app: comandos que usa la interfaz y el manifiesto que pide permisos de administrador. |
| `src/` | La interfaz en Svelte (español). |

## Cómo funciona `crear_usb`

1. Descarga las partes de la imagen a `%LOCALAPPDATA%\io.github.bel001.llevix\descargas`
   (si se corta, la próxima vez continúa) y verifica la SHA256 de cada parte y del total.
2. Descarga el `.bmap` y verifica su SHA256 y su suma interna.
3. Vuelve a comprobar que el disco es USB, no es del sistema y alcanza el tamaño;
   bloquea y desmonta sus volúmenes; borra el primer y el último MiB.
4. Descomprime zstd mientras escribe, solo los bloques con datos; comprueba cada rango
   antes de escribirlo y vuelve a leer todo al final.
5. Escribe `llevix-config.json` en la partición EFI (FAT32) sin montarla y lo relee.

La contraseña solo existe en memoria el tiempo justo para calcular su hash SHA-512.

## Desarrollo

Necesitas Rust, Node.js 20+ y (para compilar en Windows) Visual Studio Build Tools con C++.

```bash
cd creator
npm ci
npx tauri dev        # abre la app en modo desarrollo (Windows pedirá administrador)
cargo test -p llevix-nucleo
```

Sin Windows, el núcleo se puede probar en Linux (también con Docker):

```bash
docker run --rm -v "$PWD":/src -w /src rust:1 cargo test -p llevix-nucleo
```

Prueba de punta a punta (Linux con QEMU): `./tests/creador-e2e.sh xubuntu-24.04` usa el
ejemplo `escribir_en_archivo`, que hace lo mismo que el creador pero sobre un archivo.

## Seguridad

- Solo se muestran discos con bus USB. Nunca discos internos ni el del sistema (el que
  tiene Windows o el archivo de paginación), aunque estén conectados por USB.
- Antes de abrir un disco para escribir se vuelve a enumerar y a comprobar todo.
- Si el disco tiene datos, la interfaz muestra su contenido y pide doble confirmación.
- Las pruebas nunca usan discos reales: usan archivos y discos simulados.
