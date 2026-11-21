# Formato de `llevix-config.json`

El creador (o `tools/make-config.sh`) deja este archivo en la raíz de la partición
EFI (`/boot/efi/llevix-config.json` dentro de Llevix). En el primer arranque, el
servicio `llevix-firstboot` lo lee, aplica la configuración y lo **borra**.

## Ejemplo

```json
{
  "version": 1,
  "usuario": {
    "nombre": "ana",
    "nombre_completo": "Ana Pérez",
    "hash_contrasena": "$6$Wq3...$Kp9..."
  },
  "idioma": "es_MX.UTF-8",
  "zona_horaria": "America/Mexico_City",
  "teclado": {
    "distribucion": "latam",
    "variante": ""
  },
  "hostname": "llevix-ana",
  "accesibilidad": {
    "lector_pantalla": false,
    "texto_grande": false
  }
}
```

## Campos

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `version` | sí | Número. Hoy solo existe `1`. |
| `usuario.nombre` | sí | Minúsculas, números, `-` y `_`; empieza con letra; máximo 32. No puede ser un usuario del sistema (`root`, `daemon`…). |
| `usuario.nombre_completo` | no | Texto libre, máximo 100 caracteres, sin `:` ni saltos de línea. |
| `usuario.hash_contrasena` | sí | Hash SHA-512 de `crypt` (empieza con `$6$`). **Nunca** la contraseña en texto. |
| `idioma` | no | Un locale UTF-8 válido, por ejemplo `es_ES.UTF-8`. Por defecto `es_ES.UTF-8`. |
| `zona_horaria` | no | Nombre de la base tz, por ejemplo `America/Bogota`. Por defecto `UTC`. |
| `teclado.distribucion` | no | Distribución XKB (`es`, `latam`, `us`…). Por defecto `es`. |
| `teclado.variante` | no | Variante XKB o vacío. |
| `hostname` | no | Letras, números y `-`, máximo 63, sin empezar ni terminar en `-`. Por defecto `llevix`. |
| `accesibilidad.*` | no | Reservado para la fase 7g. Hoy se valida que sea `true`/`false` y se ignora. |

## Qué pasa si el archivo tiene errores

Antes de cambiar nada, `llevix-firstboot` valida **todo** el archivo. Si algo está mal:

- no crea el usuario ni cambia nada (todo o nada);
- muestra un mensaje en la pantalla de arranque;
- deja en la partición EFI el archivo `LLEVIX-ERROR.txt` con la explicación (se puede
  leer desde Windows);
- borra `llevix-config.json` (contiene el hash de la contraseña);
- el sistema sigue arrancando; si no hay ninguna cuenta, el escritorio ofrece crearla.

Si un paso falla a mitad de camino (por ejemplo, al crear el usuario), se deshace lo
que se había hecho y se informa igual.

## Cómo generar uno de prueba

```bash
./tools/make-config.sh --usuario ana --contrasena 'clave-de-prueba' > llevix-config.json
```

`llevix-config.json` está en `.gitignore`: nunca se sube al repositorio.
