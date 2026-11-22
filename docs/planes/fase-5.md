# Plan — Fase 5: creador para Windows

## Estructura (creator/)
- `nucleo/` (Rust, sin interfaz, se prueba en Linux y Windows):
  - `manifest.rs`: lee `manifest.json` (variantes, partes, sumas). Exige https y sumas válidas.
  - `descarga.rs`: descarga por partes con reanudación (`Range`), verifica SHA256 de cada
    parte y de la imagen completa; lee las partes en cadena sin unirlas en disco.
  - `bmap.rs`: lee el `.bmap` (formato bmaptool 2.0) y verifica su propia suma.
  - `escritura.rs`: descomprime zstd en streaming, escribe solo los rangos del bmap,
    comprueba la SHA256 de cada rango antes de escribirlo y verifica releyendo al final.
    Escrituras siempre alineadas a 512 bytes.
  - `gpt.rs` + `esp.rs`: encuentra la ESP en la GPT y escribe `llevix-config.json` con
    `fatfs` a través de una vista por sectores (sin que Windows monte nada).
  - `config.rs`: valida la cuenta con las mismas reglas que `firstboot.sh` y calcula el
    hash SHA-512 (`sha-crypt`); el JSON nunca contiene la contraseña.
  - `disco.rs`: filtro puro: solo bus USB, nunca el disco del sistema, tamaño mínimo,
    sectores de 512. Comprobación final justo antes de escribir.
  - `windows.rs`: enumeración real con `DeviceIoControl` (bus, tamaño, sector, volúmenes,
    disco del sistema por la letra de Windows y pagefile), bloqueo y desmontaje de
    volúmenes y apertura de `\\.\PhysicalDriveN`.
- `src-tauri/`: app Tauri 2 (pide administrador por manifiesto); comandos
  `obtener_manifest`, `preparar_cuenta`, `listar_discos`, `crear_usb`, `cancelar`.
- `src/`: interfaz Svelte 5 en español: 1) sistema, 2) cuenta, 3) disco (con contenido
  del disco y doble confirmación), progreso y pantalla final con teclas por marca y el
  aviso de no desactivar Secure Boot.

## Pruebas
- Núcleo: bmap, escritura (destino simulado en archivo y destino "estricto" que exige
  alineación), daños en la imagen, verificación, cancelación, GPT, ESP, config, filtro de
  discos con una PC simulada, descarga con servidor HTTP local que corta la conexión.
- Windows (CI): la enumeración real nunca ofrece el disco del sistema y negarse a abrirlo.
- `.github/workflows/creador.yml`: pruebas en Linux y Windows, `tauri build` y artefactos
  `.exe` (NSIS) y `.msi`.

## Decisiones
- FFI propio a kernel32 en lugar de la biblioteca `windows`: menos dependencias y
  estructuras leídas byte a byte de forma explícita.
- Se borran el primer y el último MiB del disco antes de escribir (quita la copia vieja
  de la GPT que quedaría al final de un disco más grande que la imagen).
- Discos con sectores lógicos de 4096 bytes no se ofrecen (la imagen usa 512).
