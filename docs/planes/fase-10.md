# Plan — Fase 10: "Trae tu ISO" por familias

Diseño completo: docs/planes/familias-iso.md. Aquí, el orden concreto.

## 10.1 Familias como módulos (sin cambios para el usuario)
- `image/instalador/familias.json` (versión 1): cada familia con `id`, `nombre`, `soportada`,
  señales en la ISO (`archivos`: rutas que, si alguna existe, delatan a la familia),
  quién firma su kernel para Secure Boot (`firmante`) y ejemplos de distros.
- `image/instalador/familias/<id>.sh`: funciones de nombre fijo que `instalar-iso.sh` llama:
  - `familia_sistema`: rellena `capas`, `quitar` y `kernel` desde la ISO montada en `$T/iso`;
  - `familia_quitar_vivo`: quita los programas del modo en vivo (en el sistema nuevo);
  - `familia_kernel`: deja kernel y módulos en el sistema nuevo y fija `version`;
  - `familia_initramfs`: crea el initramfs (portátil: con controladores de cualquier PC).
- `instalar-iso.sh` elige la familia leyendo `familias.json` con el `jq` de la capa,
  carga su archivo y sigue igual. El resto (copiar, capa de Llevix, fstab, GRUB, espacio)
  queda común.
- build.sh copia `familias.json` y `familias/` a `/usr/lib/llevix/familias` del instalador.
- Listo cuando: iso-propia (Mint, Kubuntu, Ubuntu) y la variante Zorin siguen verdes.

## 10.2 en adelante
Ver sección 8 de familias-iso.md.
