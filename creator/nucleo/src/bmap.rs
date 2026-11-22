//! Lectura de mapas de bloques `.bmap` (formato de bmaptool, versión 2).
//!
//! Una imagen de Llevix ocupa 28 GiB, pero solo unos pocos GB tienen datos. El `.bmap`
//! dice qué bloques tienen datos y su suma SHA256; así el creador escribe solo esos
//! bloques (mucho más rápido) y comprueba cada rango.

use crate::error::{Error, Resultado};
use sha2::{Digest, Sha256};

/// Un rango de bloques con datos (inclusive en ambos extremos).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rango {
    pub primer_bloque: u64,
    pub ultimo_bloque: u64,
    /// SHA256 de los bytes del rango, si el mapa la incluye.
    pub sha256: Option<[u8; 32]>,
}

#[derive(Debug, Clone)]
pub struct Bmap {
    pub tamano_imagen: u64,
    pub tamano_bloque: u64,
    pub rangos: Vec<Rango>,
}

impl Rango {
    pub fn desplazamiento(&self, tamano_bloque: u64) -> u64 {
        self.primer_bloque * tamano_bloque
    }
}

impl Bmap {
    /// Bytes con datos (lo que realmente se escribe).
    pub fn bytes_con_datos(&self) -> u64 {
        self.rangos.iter().map(|r| self.longitud_rango(r)).sum()
    }

    /// Longitud en bytes de un rango; el último bloque de la imagen puede ser parcial.
    pub fn longitud_rango(&self, r: &Rango) -> u64 {
        let inicio = r.primer_bloque * self.tamano_bloque;
        let fin = ((r.ultimo_bloque + 1) * self.tamano_bloque).min(self.tamano_imagen);
        fin - inicio
    }

    /// Lee y valida un `.bmap`.
    pub fn leer(texto: &str) -> Resultado<Bmap> {
        let doc = roxmltree::Document::parse(texto).map_err(|e| Error::Bmap(e.to_string()))?;
        let raiz = doc.root_element();
        if raiz.tag_name().name() != "bmap" {
            return Err(Error::Bmap("falta el elemento <bmap>".into()));
        }
        let version = raiz.attribute("version").unwrap_or("");
        if !version.starts_with("2.") {
            return Err(Error::Bmap(format!("versión no soportada: {version}")));
        }

        let numero = |nombre: &str| -> Resultado<u64> {
            let nodo = raiz
                .children()
                .find(|n| n.has_tag_name(nombre))
                .ok_or_else(|| Error::Bmap(format!("falta <{nombre}>")))?;
            nodo.text()
                .unwrap_or("")
                .trim()
                .parse::<u64>()
                .map_err(|_| Error::Bmap(format!("<{nombre}> no es un número")))
        };

        let tamano_imagen = numero("ImageSize")?;
        let tamano_bloque = numero("BlockSize")?;
        if tamano_bloque == 0 || tamano_bloque % 512 != 0 {
            return Err(Error::Bmap(format!("tamaño de bloque inválido: {tamano_bloque}")));
        }
        let bloques = tamano_imagen.div_ceil(tamano_bloque);

        let tipo_suma = raiz
            .children()
            .find(|n| n.has_tag_name("ChecksumType"))
            .and_then(|n| n.text())
            .map(|t| t.trim().to_string())
            .unwrap_or_default();
        if !tipo_suma.is_empty() && tipo_suma != "sha256" {
            return Err(Error::Bmap(format!("tipo de suma no soportado: {tipo_suma}")));
        }

        let mapa = raiz
            .children()
            .find(|n| n.has_tag_name("BlockMap"))
            .ok_or_else(|| Error::Bmap("falta <BlockMap>".into()))?;

        let mut rangos = Vec::new();
        for nodo in mapa.children().filter(|n| n.has_tag_name("Range")) {
            let texto = nodo.text().unwrap_or("").trim();
            let (a, b) = match texto.split_once('-') {
                Some((a, b)) => (a.trim(), b.trim()),
                None => (texto, texto),
            };
            let primer_bloque: u64 =
                a.parse().map_err(|_| Error::Bmap(format!("rango inválido: {texto}")))?;
            let ultimo_bloque: u64 =
                b.parse().map_err(|_| Error::Bmap(format!("rango inválido: {texto}")))?;
            if ultimo_bloque < primer_bloque || ultimo_bloque >= bloques {
                return Err(Error::Bmap(format!("rango fuera de la imagen: {texto}")));
            }
            let sha256 = match nodo.attribute("chksum") {
                Some(h) => {
                    let bytes = hex::decode(h.trim())
                        .map_err(|_| Error::Bmap(format!("suma inválida en {texto}")))?;
                    let arr: [u8; 32] = bytes
                        .try_into()
                        .map_err(|_| Error::Bmap(format!("suma de largo inválido en {texto}")))?;
                    Some(arr)
                }
                None => None,
            };
            rangos.push(Rango { primer_bloque, ultimo_bloque, sha256 });
        }

        if rangos.is_empty() {
            return Err(Error::Bmap("el mapa no tiene rangos".into()));
        }
        for par in rangos.windows(2) {
            if par[1].primer_bloque <= par[0].ultimo_bloque {
                return Err(Error::Bmap("rangos desordenados o superpuestos".into()));
            }
        }

        Ok(Bmap { tamano_imagen, tamano_bloque, rangos })
    }

    /// Comprueba la suma del propio archivo `.bmap` (campo BmapFileChecksum), que se
    /// calcula con ese campo reemplazado por ceros.
    pub fn verificar_archivo(texto: &str) -> Resultado<()> {
        let inicio = texto
            .find("<BmapFileChecksum>")
            .ok_or_else(|| Error::Bmap("falta <BmapFileChecksum>".into()))?
            + "<BmapFileChecksum>".len();
        let fin = texto[inicio..]
            .find("</BmapFileChecksum>")
            .ok_or_else(|| Error::Bmap("<BmapFileChecksum> sin cerrar".into()))?
            + inicio;
        let esperado = texto[inicio..fin].trim().to_ascii_lowercase();
        let ceros = texto[inicio..fin].replace(|c: char| c.is_ascii_hexdigit(), "0");
        let normalizado = format!("{}{}{}", &texto[..inicio], ceros, &texto[fin..]);
        let real = hex::encode(Sha256::digest(normalizado.as_bytes()));
        if real != esperado {
            return Err(Error::Bmap("la suma del archivo .bmap no coincide".into()));
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod pruebas {
    use super::*;

    /// Genera un .bmap (con su BmapFileChecksum) para una imagen en memoria, como
    /// haría `bmaptool create`: un rango por cada tramo de bloques que no son todo ceros.
    pub fn crear_bmap(imagen: &[u8], tamano_bloque: usize) -> String {
        let bloques = imagen.len().div_ceil(tamano_bloque);
        let mut rangos: Vec<(usize, usize)> = Vec::new();
        for b in 0..bloques {
            let ini = b * tamano_bloque;
            let fin = ((b + 1) * tamano_bloque).min(imagen.len());
            if imagen[ini..fin].iter().any(|&x| x != 0) {
                match rangos.last_mut() {
                    Some(r) if r.1 + 1 == b => r.1 = b,
                    _ => rangos.push((b, b)),
                }
            }
        }
        let mut xml = String::new();
        xml.push_str("<?xml version=\"1.0\" ?>\n<bmap version=\"2.0\">\n");
        xml.push_str(&format!("    <ImageSize> {} </ImageSize>\n", imagen.len()));
        xml.push_str(&format!("    <BlockSize> {tamano_bloque} </BlockSize>\n"));
        xml.push_str(&format!("    <BlocksCount> {bloques} </BlocksCount>\n"));
        xml.push_str("    <ChecksumType> sha256 </ChecksumType>\n");
        xml.push_str(&format!("    <BmapFileChecksum> {} </BmapFileChecksum>\n", "0".repeat(64)));
        xml.push_str("    <BlockMap>\n");
        for (a, b) in &rangos {
            let ini = a * tamano_bloque;
            let fin = ((b + 1) * tamano_bloque).min(imagen.len());
            let suma = hex::encode(Sha256::digest(&imagen[ini..fin]));
            if a == b {
                xml.push_str(&format!("        <Range chksum=\"{suma}\"> {a} </Range>\n"));
            } else {
                xml.push_str(&format!("        <Range chksum=\"{suma}\"> {a}-{b} </Range>\n"));
            }
        }
        xml.push_str("    </BlockMap>\n</bmap>\n");
        let suma = hex::encode(Sha256::digest(xml.as_bytes()));
        xml.replace(&"0".repeat(64), &suma)
    }

    #[test]
    fn lee_un_mapa_valido() {
        let mut img = vec![0u8; 4096 * 10];
        img[0] = 1;
        img[4096 * 3] = 2;
        img[4096 * 4 + 5] = 3;
        img[4096 * 9 + 100] = 4;
        let texto = crear_bmap(&img, 4096);
        let bmap = Bmap::leer(&texto).unwrap();
        assert_eq!(bmap.tamano_imagen, 40960);
        assert_eq!(bmap.rangos.len(), 3);
        assert_eq!((bmap.rangos[1].primer_bloque, bmap.rangos[1].ultimo_bloque), (3, 4));
        assert_eq!(bmap.bytes_con_datos(), 4 * 4096);
        Bmap::verificar_archivo(&texto).unwrap();
    }

    #[test]
    fn detecta_un_mapa_alterado() {
        let mut img = vec![0u8; 8192];
        img[10] = 1;
        let texto = crear_bmap(&img, 4096).replace("> 0 <", "> 1 <");
        assert!(Bmap::verificar_archivo(&texto).is_err());
    }

    #[test]
    fn rechaza_rangos_fuera_de_la_imagen() {
        let texto = "<bmap version=\"2.0\"><ImageSize>8192</ImageSize><BlockSize>4096</BlockSize>\
            <BlockMap><Range>0-5</Range></BlockMap></bmap>";
        assert!(Bmap::leer(texto).is_err());
    }

    #[test]
    fn rechaza_rangos_superpuestos() {
        let texto = "<bmap version=\"2.0\"><ImageSize>40960</ImageSize><BlockSize>4096</BlockSize>\
            <BlockMap><Range>0-3</Range><Range>2-5</Range></BlockMap></bmap>";
        assert!(Bmap::leer(texto).is_err());
    }
}
