//! `manifest.json` de un Release: qué variantes hay y dónde descargarlas.
//! Lo genera `tools/manifest.sh` en el workflow de publicación.

use crate::error::{Error, Resultado};
use serde::{Deserialize, Serialize};

/// Repositorio donde se publican las versiones.
pub const REPOSITORIO: &str = "bel001/Llevix";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Parte {
    pub url: String,
    pub tamano: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Variante {
    pub id: String,
    pub nombre: String,
    #[serde(default)]
    pub descripcion: String,
    #[serde(default)]
    pub base: String,
    #[serde(default)]
    pub ligera: bool,
    pub tamano_comprimido: u64,
    /// Tamaño de la imagen sin comprimir = tamaño mínimo del disco.
    pub tamano_imagen: u64,
    /// SHA256 de la imagen comprimida completa (todas las partes unidas).
    pub sha256: String,
    pub partes: Vec<Parte>,
    pub bmap_url: String,
    pub bmap_sha256: String,
    #[serde(default)]
    pub paquetes_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Manifest {
    pub formato: u32,
    pub version: String,
    #[serde(default)]
    pub fecha: String,
    pub variantes: Vec<Variante>,
}

fn es_sha256(s: &str) -> bool {
    s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit())
}

impl Manifest {
    pub fn leer(texto: &str) -> Resultado<Manifest> {
        let m: Manifest = serde_json::from_str(texto).map_err(|e| Error::Manifest(e.to_string()))?;
        if m.formato != 1 {
            return Err(Error::Manifest(format!(
                "formato {} no soportado: actualiza el creador de Llevix",
                m.formato
            )));
        }
        if m.variantes.is_empty() {
            return Err(Error::Manifest("no hay variantes".into()));
        }
        for v in &m.variantes {
            let suma_partes: u64 = v.partes.iter().map(|p| p.tamano).sum();
            let urls_ok = v.partes.iter().all(|p| p.url.starts_with("https://"))
                && v.bmap_url.starts_with("https://");
            if v.partes.is_empty()
                || suma_partes != v.tamano_comprimido
                || !urls_ok
                || !es_sha256(&v.sha256)
                || !es_sha256(&v.bmap_sha256)
                || !v.partes.iter().all(|p| es_sha256(&p.sha256))
                || v.tamano_imagen == 0
            {
                return Err(Error::Manifest(format!("la variante '{}' tiene datos inválidos", v.id)));
            }
        }
        Ok(m)
    }
}

/// URL del manifest de la última versión estable.
pub fn url_ultimo_manifest() -> String {
    format!("https://github.com/{REPOSITORIO}/releases/latest/download/manifest.json")
}

/// Busca el manifest de la última versión estable; si todavía no hay ninguna estable,
/// usa la versión de prueba (pre-release) más reciente.
pub fn buscar_ultimo() -> Resultado<Manifest> {
    use crate::descarga::descargar_texto;

    if let Ok(texto) = descargar_texto(&url_ultimo_manifest()) {
        return Manifest::leer(&texto);
    }
    let lista = descargar_texto(&format!("https://api.github.com/repos/{REPOSITORIO}/releases?per_page=20"))?;
    let versiones: serde_json::Value =
        serde_json::from_str(&lista).map_err(|e| Error::Manifest(e.to_string()))?;
    for v in versiones.as_array().into_iter().flatten() {
        if v["draft"].as_bool() == Some(true) {
            continue;
        }
        let url = v["assets"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|a| a["name"] == "manifest.json")
            .and_then(|a| a["browser_download_url"].as_str());
        if let Some(url) = url {
            return Manifest::leer(&descargar_texto(url)?);
        }
    }
    Err(Error::Manifest("todavía no hay ninguna versión publicada".into()))
}

#[cfg(test)]
mod pruebas {
    use super::*;

    pub const EJEMPLO: &str = r#"{
      "formato": 1, "version": "v0.1.0", "fecha": "2026-11-21T00:00:00Z",
      "variantes": [{
        "id": "xubuntu-24.04", "nombre": "Llevix, basado en Xubuntu 24.04 LTS",
        "descripcion": "Xfce: liviano.", "base": "ubuntu", "ligera": true,
        "tamano_comprimido": 300, "tamano_imagen": 30064771072,
        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "partes": [
          {"url": "https://example.org/x.img.zst.001", "tamano": 200, "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
          {"url": "https://example.org/x.img.zst.002", "tamano": 100, "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
        ],
        "bmap_url": "https://example.org/x.img.bmap",
        "bmap_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "paquetes_url": "https://example.org/x.paquetes.txt"
      }]
    }"#;

    #[test]
    fn lee_un_manifest_valido() {
        let m = Manifest::leer(EJEMPLO).unwrap();
        assert_eq!(m.variantes.len(), 1);
        assert!(m.variantes[0].ligera);
        assert_eq!(m.variantes[0].partes.len(), 2);
    }

    #[test]
    fn rechaza_partes_que_no_suman_el_total() {
        let malo = EJEMPLO.replace("\"tamano\": 100", "\"tamano\": 99");
        assert!(Manifest::leer(&malo).is_err());
    }

    #[test]
    fn rechaza_urls_sin_https() {
        let malo = EJEMPLO.replace("https://example.org/x.img.zst.001", "http://example.org/x.img.zst.001");
        assert!(Manifest::leer(&malo).is_err());
    }

    #[test]
    fn rechaza_formatos_futuros() {
        let malo = EJEMPLO.replace("\"formato\": 1", "\"formato\": 2");
        assert!(Manifest::leer(&malo).is_err());
    }
}
