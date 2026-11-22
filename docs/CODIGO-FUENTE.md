# Código fuente de Llevix

Llevix está hecho de software libre. Hay dos partes, con licencias distintas:

| Parte | Licencia | Dónde está el código |
| --- | --- | --- |
| Lo que escribimos nosotros: scripts de construcción, primer arranque, creador, pruebas | [MIT](../LICENSE) | Este repositorio, en la etiqueta de cada versión |
| Lo que trae cada imagen: Linux, el escritorio, los programas… (de Ubuntu, Linux Mint, Debian o Zorin OS) | La de cada programa (GPL, LGPL, MPL, MIT, BSD…) | Ver abajo |

## Cómo obtener el código fuente de una imagen

Cada versión publicada en [Releases](https://github.com/bel001/Llevix/releases) incluye:

- `llevix-<variante>.paquetes.txt`: cada paquete de la imagen con su versión exacta y el
  paquete fuente del que sale (columnas: paquete, versión, paquete fuente, versión fuente).
- `llevix-fuentes-<base>.tar.001`, `.002`…: el código fuente de **todos** esos paquetes,
  tal como lo publica la distribución (archivos `.dsc`, `.orig.tar.*`, `.debian.tar.*`).
  `<base>` es `ubuntu` (Ubuntu, Kubuntu, Xubuntu, Lubuntu y el instalador), `mint`,
  `debian` o `zorin`. Se agregan al Release poco después de publicarlo.
- `llevix-fuentes-<base>.tar.sha256`: la suma para comprobar la descarga.
- `llevix-fuentes-<base>.faltantes.txt`: los pocos paquetes cuyo código no se pudo
  descargar automáticamente, con dónde encontrarlo (por ejemplo, los paquetes propios de
  Zorin OS, que Zorin publica en <https://github.com/ZorinOS>, y las traducciones de
  Firefox, en <https://github.com/mozilla-l10n/firefox-l10n>).

Para usarlo, une las partes en orden y extrae el `.tar`:

```bash
cat llevix-fuentes-ubuntu.tar.0* > llevix-fuentes-ubuntu.tar
sha256sum -c llevix-fuentes-ubuntu.tar.sha256
tar -xf llevix-fuentes-ubuntu.tar
cd nano && dpkg-source -x nano_*.dsc    # por ejemplo
```

En Windows: `copy /b llevix-fuentes-ubuntu.tar.001 + llevix-fuentes-ubuntu.tar.002 llevix-fuentes-ubuntu.tar`
y luego ábrelo con 7-Zip.

Firefox se distribuye tal como lo publica Mozilla; su código está en el mismo `.tar`
(`firefox/firefox-<versión>.source.tar.xz`) y en <https://archive.mozilla.org/pub/firefox/releases/>.

## Oferta escrita

Durante **al menos tres (3) años** desde la última vez que distribuyamos una versión de
Llevix, entregaremos a cualquier persona que lo pida una copia completa, legible por
máquina, del código fuente correspondiente a los programas incluidos en esa versión que
estén bajo la GNU GPL, la GNU LGPL u otra licencia que lo exija, por un costo no mayor
que el de hacer la copia (por descarga, gratis).

Para pedirlo, abre un *issue* en <https://github.com/bel001/Llevix/issues> con el título
«Código fuente» y la versión y variante que tienes (está en `/etc/llevix/version` dentro de
Llevix).

## Written offer (English)

For at least three (3) years from the last time we distribute a given version of Llevix,
we will give any third party who asks a complete machine-readable copy of the
corresponding source code of the programs in that version that are licensed under the
GNU GPL, the GNU LGPL or any other license that requires it, for a charge no more than
the cost of physically performing the distribution (free of charge by download). To
request it, open an issue at <https://github.com/bel001/Llevix/issues> titled "Source
code" with your Llevix version and variant (see `/etc/llevix/version`).

## Para quienes mantienen Llevix

- Al publicar una versión (`release.yml`), el trabajo `fuentes` ejecuta
  [`.github/workflows/fuentes.yml`](../.github/workflows/fuentes.yml), que usa
  [`tools/fuentes.sh`](../tools/fuentes.sh) en un contenedor por cada base.
- Si una versión exacta ya no está en los repositorios, el script la busca en los archivos
  permanentes: Launchpad (Ubuntu), el *pool* de Linux Mint y snapshot.debian.org (Debian).
- Para una versión publicada antes de existir esto: **Actions → fuentes → Run workflow**
  con la etiqueta.
- Si alguien pide el código por un *issue*, hay que responder con el enlace al Release (o
  generar lo que falte). Es una obligación por tres años.
