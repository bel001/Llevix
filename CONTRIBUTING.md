# Cómo contribuir a Llevix

Gracias por querer ayudar. Esta guía explica cómo preparar tu entorno y cómo
trabajamos en el proyecto.

## 1. Preparar el entorno

Llevix tiene dos partes que se construyen en lugares distintos:

| Parte                    | Dónde se trabaja                         |
|--------------------------|------------------------------------------|
| Imágenes (`image/`) y pruebas (`tests/`) | Linux, o WSL2 con Ubuntu 24.04 en Windows |
| Creador (`creator/`)     | Windows (Rust, Node.js, Visual Studio Build Tools, WebView2) |
| Sitio web (`web/`)       | Cualquiera de los dos (Node.js)          |

Ejecuta el verificador en cada lugar donde vayas a trabajar. En Windows usa
Git Bash; en Linux o WSL, una terminal normal:

```bash
./tools/check-env.sh
```

El script dice qué falta y qué comando usar para instalarlo. No instala nada por
su cuenta.

### Consejo para WSL

Clona el repositorio dentro del sistema de archivos de Linux (por ejemplo
`~/Llevix`), no en `/mnt/c/...`. Es mucho más rápido y evita problemas de permisos
al construir imágenes.

## 2. Ramas y commits

- Cada fase del plan se hace en su propia rama: `fase-N-descripcion`
  (por ejemplo `fase-1-imagen-base`).
- Commits pequeños, con un mensaje en español que diga qué cambia y por qué:
  `image: activar compresión zstd en btrfs`.
- Los cambios entran a `main` mediante un pull request.

## 3. Reglas del código

- Todo en español: comentarios, mensajes al usuario y documentación.
- Los scripts de bash empiezan con `set -euo pipefail` y deben pasar `shellcheck`.
- Los archivos usan fin de línea LF (`.gitattributes` ya lo aplica).
- Nunca guardar contraseñas en texto plano: solo hash SHA-512.
- Nada atado a un hardware concreto: sin `xorg.conf` fijo ni drivers propietarios.
- El creador nunca debe mostrar ni escribir discos internos o el disco del sistema.

## 4. Pruebas

- Todo cambio en `image/` debe pasar `tests/qemu-boot-test.sh` en UEFI (con
  Secure Boot) y en BIOS antes de abrir el pull request.
- Si una prueba falla, se arregla antes de seguir.

## 5. Licencias y marcas

- La licencia del proyecto (GPL-3.0 o MIT) está pendiente. Mientras tanto:
  no copies código GPL de otros proyectos y usa solo dependencias compatibles
  con ambas licencias (por ejemplo MIT, BSD, Apache-2.0).
- No uses los logos ni los nombres "Ubuntu" o "Linux Mint" como marca del
  producto. Escribe "Llevix, basado en Ubuntu".

## 6. Seguridad para los usuarios

- Nunca pedir al usuario que desactive Secure Boot: puede activar la recuperación
  de BitLocker en su Windows. Indicar siempre el menú de arranque de una sola vez
  (F12, F9, Esc).
- Si el disco elegido tiene datos, el creador muestra su contenido y pide doble
  confirmación antes de borrarlo.
