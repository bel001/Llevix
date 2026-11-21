# Fase 3 — Portabilidad y resistencia

**Objetivo:** el mismo USB funciona en muchas PCs distintas y sobrevive a
desconexiones bruscas. Todas las variantes de distro de la v1 se construyen.
**Tiempo aprox.:** 1–2 semanas.

## Prompt

```
Fase 3. Primero escribe el plan en docs/planes/fase-3.md.

Portabilidad:
- initramfs con todos los módulos (MODULES=most), sin configuración de hardware fija;
- entrada de GRUB "Modo gráficos seguros" (nomodeset);
- NetworkManager sin conexiones atadas a una tarjeta concreta;
- nombre de interfaces de red predecible y genérico.

Cuidar el disco:
- journald en memoria (Storage=volatile), noatime, /tmp en RAM;
- TRIM periódico (fstrim.timer) para SSD y NVMe;
- evitar que discos externos se apaguen por ahorro de energía;
- planificador de E/S adecuado para HDD vs SSD (regla udev).

Resistencia:
- snapshots btrfs automáticos antes de cada actualización de apt;
- opción en GRUB para arrancar desde un snapshot anterior;
- prueba en QEMU que simule apagado brusco (matar QEMU durante una escritura)
  y verifique que el sistema vuelve a arrancar.

Variantes de distro:
- crea image/distros/ para: ubuntu, kubuntu, xubuntu, lubuntu (24.04) y
  mint-cinnamon, mint-mate, mint-xfce (22). Cada variante entrega su escritorio
  original sin cambios.
- el workflow construye y prueba todas las variantes (matriz de GitHub Actions).
Itera hasta que todo pase.
```

## Qué haces tú (IMPORTANTE)
- Descarga una imagen del CI, escríbela con Rufus (modo DD) y pruébala en **al
  menos 3 PCs reales**. Anota los resultados en `tests/hardware-matrix.md`.
- Si algo falla, escribe en `PENDIENTES.md` o dile a Claude Code qué pasó.

## Listo cuando
- [ ] Todas las variantes construyen y pasan en CI
- [ ] La prueba de apagado brusco pasa
- [ ] Funciona en al menos 3 PCs reales (prueba humana)
