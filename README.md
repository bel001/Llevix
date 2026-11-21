# Llevix

Llevix convierte una memoria USB o un disco externo (HDD, SSD o NVMe en caja USB)
en un Linux portátil y persistente que arranca en cualquier PC x86_64.

Eliges la distribución, escribes tu usuario y contraseña, y el disco queda listo.
Tus archivos se conservan de una computadora a otra, y la partición de datos
también se abre desde Windows y desde el celular.

> Estado: en desarrollo temprano (Fase 0). Todavía no hay versión para usar.

## Distribuciones previstas para la v1

Llevix, basado en Ubuntu 24.04 LTS (variantes Ubuntu, Kubuntu, Xubuntu, Lubuntu)
y Llevix, basado en Linux Mint 22 (Cinnamon, MATE, Xfce). Cada variante se entrega
con el escritorio tal como lo trae su distribución.

## Estructura del repositorio

| Carpeta    | Contenido                                                      |
|------------|----------------------------------------------------------------|
| `image/`   | Construcción de las imágenes `.img` (bash + debootstrap)       |
| `creator/` | App para Windows que escribe la imagen al disco (Tauri + Svelte) |
| `tests/`   | Pruebas de arranque en QEMU (UEFI, Secure Boot y BIOS)         |
| `tools/`   | Herramientas de desarrollo, como `check-env.sh`                |
| `docs/`    | Documentación del proyecto                                     |
| `web/`     | Sitio web (Astro)                                              |

## Empezar a desarrollar

```bash
./tools/check-env.sh
```

Revisa [CONTRIBUTING.md](CONTRIBUTING.md) para preparar el entorno y conocer las reglas.

## Licencia

Pendiente de decidir (GPL-3.0 o MIT).
