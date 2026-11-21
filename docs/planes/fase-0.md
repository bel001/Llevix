# Plan — Fase 0: arranque del proyecto

1. Estructura de carpetas: image/ (distros, overlay, firstboot), creator/, tests/,
   tools/, docs/, web/, .github/workflows/.
2. README.md y CONTRIBUTING.md en español.
3. .gitignore y .gitattributes (fin de línea LF: los scripts de bash fallan con CRLF).
4. tools/check-env.sh: detecta si corre en Windows (Git Bash), WSL o Linux y revisa
   lo necesario en cada lugar. No instala nada; dice el comando para instalar.
5. .github/workflows/lint.yml: shellcheck sobre todos los .sh.
6. Probar localmente: check-env.sh y shellcheck (con Docker, porque no está instalado).
7. Fusionar en main, push y comprobar que lint pasa en GitHub.
