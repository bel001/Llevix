# Fase 7 — Funciones después de la v1

Una función por versión. Pega un prompt a la vez, en este orden de prioridad.
La web (7i) conviene hacerla en paralelo con la fase 6.

## 7a — Cifrado del disco (LUKS)
```
Escribe el plan en docs/planes/fase-7a.md. Quiero cifrado LUKS2 opcional para la
partición del sistema, usando la contraseña del usuario. Como la imagen se escribe
ya hecha, compara cifrar en el primer arranque (cryptsetup reencrypt) contra cifrar
al crear el USB, elige la mejor y anota la decisión. LLEVIX-DATOS queda sin cifrar
para que el celular la lea; el creador debe explicarlo. Pruebas en CI.
```

## 7b — Actualizaciones de Llevix
```
Crea el paquete llevix-tools con repositorio APT propio (publicado con GitHub
Pages), para que los ajustes y servicios de Llevix se actualicen con apt. Cada
actualización crea antes un snapshot btrfs. Notificación en el escritorio cuando
haya versión nueva. Pruebas en CI.
```

## 7c — Copias de seguridad y restauración
```
Agrega al creador "Respaldar mi Llevix" (copia comprimida y cifrada del sistema y
los datos a un archivo) y "Restaurar en un USB nuevo" (funciona aunque el disco
nuevo tenga otro tamaño). Prueba la restauración en CI con un disco virtual más
grande y uno más chico.
```

## 7d — Salud del disco
```
Crea un servicio que revise la salud del disco con smartctl (SSD, NVMe, HDD) y
detecte errores de lectura/escritura en memorias USB. Muestra un aviso claro en el
escritorio cuando convenga hacer un respaldo.
```

## 7e — Reporte de errores opcional
```
Convierte tools/report.sh en una app gráfica "Reportar un problema": recopila los
datos, quita información personal, muestra exactamente qué se enviará y solo con
permiso del usuario abre un issue en GitHub. Nunca enviar nada automáticamente.
```

## 7f — Modo invitado sin rastro
```
Agrega en GRUB la entrada "Modo invitado": sistema en solo lectura con cambios en
RAM (overlayfs), sin montar LLEVIX-DATOS. Al apagar no queda nada. Prueba en CI.
```

## 7g — Accesibilidad
```
Activa desde el primer arranque el atajo del lector de pantalla Orca y un atajo de
alto contraste, y agrega al creador las opciones "lector de pantalla" y "texto
grande", que se apliquen en el primer arranque mediante llevix-config.json.
```

## 7h — Sincronización en la nube
```
Agrega una app de configuración que, si el usuario quiere, sincronice ~/Datos con
Nextcloud o Google Drive usando rclone, con asistente en español y sin guardar
credenciales en texto plano.
```

## 7i — Web y documentación en español
```
Crea en web/ un sitio con Astro, en español, publicado con GitHub Pages: inicio,
descarga (lee manifest.json), preguntas frecuentes y guía "Cómo arrancar desde USB"
por marca (HP, Lenovo, Dell, Asus, Acer, MSI, Toshiba, Samsung) con la tecla del
menú de arranque y la advertencia de no desactivar Secure Boot.
```
