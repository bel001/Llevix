# Fase 0 — Arranque del proyecto

**Objetivo:** repositorio ordenado, entorno verificado y CI básico funcionando.
**Tiempo aprox.:** 1 día.

## Prompt

```
Lee CLAUDE.md. Vamos a hacer la Fase 0.
1. Crea la estructura de carpetas descrita en CLAUDE.md (image/, creator/, tests/,
   tools/, docs/, .github/workflows/).
2. Crea README.md en español: qué es Llevix, estado "en desarrollo", cómo contribuir.
3. Crea CONTRIBUTING.md en español.
4. Crea tools/check-env.sh: verifica los paquetes necesarios (debootstrap,
   qemu-system-x86, ovmf, parted, dosfstools, exfatprogs, btrfs-progs, zstd,
   bmap-tools, shellcheck, git, gh) y muestra cómo instalar los que falten.
5. Crea .github/workflows/lint.yml que ejecute shellcheck en todos los .sh.
6. Ejecuta check-env.sh y shellcheck localmente.
7. Commit, push y verifica con gh run watch que el workflow pasa.
8. Actualiza "Estado actual" en CLAUDE.md.
```

## Qué haces tú
- Nada, salvo instalar los paquetes que `check-env.sh` diga que faltan (te dará el comando).

## Listo cuando
- [ ] Existen las carpetas, README.md y CONTRIBUTING.md
- [ ] `./tools/check-env.sh` termina sin faltantes
- [ ] El workflow de lint pasa en GitHub (check verde)
