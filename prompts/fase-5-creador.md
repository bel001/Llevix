# Fase 5 — Creador para Windows

**Objetivo:** app con asistente de 3 pasos que deja un USB o disco externo listo.
**Tiempo aprox.:** 2–3 semanas.

## Prompt

```
Fase 5. Primero escribe el plan en docs/planes/fase-5.md.

Crea en creator/ una app Tauri 2 + Svelte, interfaz en español, asistente de 3 pasos:
1) Elegir distro: lee manifest.json del último Release; muestra variantes con
   etiqueta "Ligera" donde corresponda.
2) Cuenta: usuario, contraseña (con confirmación), idioma, zona horaria, teclado.
   La contraseña se convierte a hash SHA-512 en el momento; nunca se guarda en texto.
3) Destino: lista SOLO discos conectados por USB (memorias y discos externos
   HDD/SSD/NVMe). En Windows muchos discos externos no figuran como "extraíbles":
   filtra por tipo de bus USB. Nunca muestres discos internos ni el disco del
   sistema. Si el disco tiene datos, muestra qué contiene y pide doble confirmación.

Escritura (Rust):
- descarga con reanudación, verifica SHA256;
- descomprime zstd en streaming y escribe solo los bloques del .bmap en
  \\.\PhysicalDriveN, con permisos de administrador;
- verifica lo escrito;
- crea llevix-config.json en la ESP;
- barra de progreso y mensajes claros.
Pantalla final: cómo arrancar desde USB según la marca de PC, con la advertencia
de no desactivar Secure Boot (BitLocker).

Pruebas:
- pruebas unitarias del filtro de discos con discos simulados (nunca reales);
- pruebas de escritura usando un archivo de imagen como destino simulado;
- workflow en windows-latest que compile, pruebe y genere el instalador .msi/.exe.
Itera hasta que todo pase. Agrega el instalador al Release de la fase 4.
```

## Qué haces tú (IMPORTANTE)
- Instala el creador en una PC con Windows y crea un USB real con él.
- **Primero desconecta cualquier disco externo con datos importantes.**
- Comprueba que el USB arranca y que el usuario y la contraseña funcionan.
- Decide cómo firmar el instalador (ver GUIA.md, sección 8).

## Listo cuando
- [ ] El instalador se genera en CI y pasan las pruebas
- [ ] El filtro de discos nunca muestra discos internos (pruebas)
- [ ] Creaste un USB real con el creador y arrancó (prueba humana)
