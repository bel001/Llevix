//! "Trae tu ISO": revisar la ISO que eligió el usuario y dejarla en el disco.
//!
//! El disco se escribe con la imagen "Llevix instalador". Su partición 4 (24 GiB) tiene
//! btrfs solo en los primeros 16 GiB; desde ahí va un encabezado de 1 MiB y la ISO tal
//! cual. En el primer arranque, `image/instalador/instalar-iso.sh` la instala.
//! Las constantes y el formato del encabezado deben coincidir con ese script.
//!
//! El lector de ISO 9660 es mínimo: solo busca archivos por ruta usando los nombres
//! Joliet (UCS-2) o, si no hay, los nombres Rock Ridge / ISO 9660 de la ISO.
//!
//! La ISO se reconoce por cómo está armada (su **familia**), no por su nombre: las señales
//! están en `image/instalador/familias.json`, el mismo archivo que usa el instalador. Las
//! ISOs que pasaron las pruebas de CI están en `tests/compatibilidad-isos.json`.

use crate::error::{Error, Resultado};
use crate::gpt;
use sha2::{Digest, Sha256};
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};

pub const INICIO_RESERVA: u64 = 16 * 1024 * 1024 * 1024;
pub const ENCABEZADO: u64 = 1024 * 1024;
pub const MAX_ISO: u64 = 8 * 1024 * 1024 * 1024 - ENCABEZADO;
const SECTOR_ISO: u64 = 2048;

/// Cómo trae el sistema la ISO.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TipoIso {
    /// Ubuntu 24.04 y posteriores: capas descritas en casper/install-sources.yaml.
    Capas,
    /// casper/filesystem.squashfs (Mint, sabores de Ubuntu, Zorin, elementary…).
    Squashfs,
}

/// Qué tan seguro es que la ISO funcione.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Nivel {
    /// Esta misma ISO (tamaño y SHA256) pasó las pruebas de Llevix.
    Probada,
    /// Su familia está soportada, pero esta ISO no se probó.
    Familia,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct InfoIso {
    /// Nombre de la distro según .disk/info (o el nombre del archivo si no hay).
    pub nombre: String,
    pub tipo: TipoIso,
    pub tamano: u64,
    /// Familia reconocida (id de familias.json) y su nombre para mostrar.
    pub familia: String,
    pub nombre_familia: String,
    pub nivel: Nivel,
    /// Si es una ISO probada: su nombre en la lista (por ejemplo "Kubuntu 24.04.5").
    pub probada_como: Option<String>,
}

/// Una familia de familias.json.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Familia {
    pub id: String,
    pub nombre: String,
    pub soportada: bool,
    /// Rutas dentro de la ISO que, si alguna existe, delatan a la familia.
    pub archivos: Vec<String>,
    /// Carpetas de la ISO donde la familia guarda su kernel (vmlinuz…).
    pub carpetas_kernel: Vec<String>,
    pub ejemplos: Vec<String>,
}

#[derive(serde::Deserialize)]
struct ArchivoFamilias {
    version: u32,
    familias: Vec<Familia>,
}

/// Una ISO probada de tests/compatibilidad-isos.json.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Probada {
    pub nombre: String,
    pub familia: String,
    pub tamano: u64,
    pub sha256: String,
}

#[derive(serde::Deserialize)]
struct ArchivoProbadas {
    version: u32,
    isos: Vec<Probada>,
}

const FAMILIAS_JSON: &str = include_str!("../../../image/instalador/familias.json");
const PROBADAS_JSON: &str = include_str!("../../../tests/compatibilidad-isos.json");

/// Familias que Llevix reconoce (las pruebas comprueban que el archivo es válido).
pub fn familias() -> &'static [Familia] {
    static F: std::sync::OnceLock<Vec<Familia>> = std::sync::OnceLock::new();
    F.get_or_init(|| {
        let a: ArchivoFamilias = serde_json::from_str(FAMILIAS_JSON).expect("familias.json no es válido");
        assert_eq!(a.version, 1, "versión de familias.json no soportada");
        a.familias
    })
}

/// ISOs probadas en CI.
pub fn probadas() -> &'static [Probada] {
    static P: std::sync::OnceLock<Vec<Probada>> = std::sync::OnceLock::new();
    P.get_or_init(|| {
        let a: ArchivoProbadas = serde_json::from_str(PROBADAS_JSON).expect("compatibilidad-isos.json no es válido");
        assert_eq!(a.version, 1, "versión de compatibilidad-isos.json no soportada");
        a.isos
    })
}

fn ejemplos_soportados() -> String {
    familias().iter().filter(|f| f.soportada).flat_map(|f| f.ejemplos.iter().cloned()).collect::<Vec<_>>().join(", ")
}

/// Una entrada de directorio de ISO 9660.
#[derive(Debug, Clone)]
struct Entrada {
    nombre: String,
    sector: u32,
    tamano: u32,
    es_dir: bool,
}

struct Volumen {
    raiz_sector: u32,
    raiz_tamano: u32,
    joliet: bool,
}

fn leer_sector<R: Read + Seek>(r: &mut R, sector: u64, buf: &mut [u8]) -> Resultado<()> {
    r.seek(SeekFrom::Start(sector * SECTOR_ISO))?;
    r.read_exact(buf)?;
    Ok(())
}

/// Busca el descriptor Joliet (preferido) o el primario.
fn volumen<R: Read + Seek>(r: &mut R) -> Resultado<Volumen> {
    let mut primario = None;
    let mut buf = vec![0u8; SECTOR_ISO as usize];
    for s in 16..64u64 {
        if leer_sector(r, s, &mut buf).is_err() {
            break;
        }
        if &buf[1..6] != b"CD001" {
            return Err(Error::Config("el archivo no es una imagen ISO".into()));
        }
        let raiz = &buf[156..190];
        let sector = u32::from_le_bytes(raiz[2..6].try_into().unwrap());
        let tamano = u32::from_le_bytes(raiz[10..14].try_into().unwrap());
        match buf[0] {
            1 => primario = Some(Volumen { raiz_sector: sector, raiz_tamano: tamano, joliet: false }),
            2 if buf[88] == 0x25 && buf[89] == 0x2F && matches!(buf[90], 0x40 | 0x43 | 0x45) => {
                return Ok(Volumen { raiz_sector: sector, raiz_tamano: tamano, joliet: true });
            }
            255 => break,
            _ => {}
        }
    }
    primario.ok_or_else(|| Error::Config("la ISO no tiene descriptor de volumen".into()))
}

/// Nombre Rock Ridge (entrada "NM") dentro del área de uso del sistema, si existe.
fn nombre_rock_ridge(uso: &[u8]) -> Option<String> {
    let mut i = 0;
    let mut nombre = String::new();
    while i + 4 <= uso.len() {
        let largo = uso[i + 2] as usize;
        if largo < 4 || i + largo > uso.len() {
            break;
        }
        if &uso[i..i + 2] == b"NM" && largo >= 5 {
            nombre.push_str(&String::from_utf8_lossy(&uso[i + 5..i + largo]));
        }
        i += largo;
    }
    (!nombre.is_empty()).then_some(nombre)
}

fn leer_directorio<R: Read + Seek>(r: &mut R, sector: u32, tamano: u32, joliet: bool) -> Resultado<Vec<Entrada>> {
    let tamano = tamano.min(16 * 1024 * 1024) as usize;
    let mut datos = vec![0u8; tamano.div_ceil(SECTOR_ISO as usize) * SECTOR_ISO as usize];
    leer_sector(r, sector as u64, &mut datos)?;
    let mut entradas = Vec::new();
    let mut i = 0;
    while i < tamano {
        let largo = datos[i] as usize;
        if largo == 0 {
            // El resto del sector está vacío: sigue en el próximo sector.
            i = (i / SECTOR_ISO as usize + 1) * SECTOR_ISO as usize;
            continue;
        }
        if i + largo > datos.len() || largo < 34 {
            break;
        }
        let e = &datos[i..i + largo];
        let largo_nombre = e[32] as usize;
        if 33 + largo_nombre > e.len() {
            break;
        }
        let crudo = &e[33..33 + largo_nombre];
        if !(largo_nombre == 1 && (crudo[0] == 0 || crudo[0] == 1)) {
            let nombre = if joliet {
                let u: Vec<u16> = crudo.chunks_exact(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
                String::from_utf16_lossy(&u)
            } else {
                let inicio_uso = 33 + largo_nombre + (1 - largo_nombre % 2);
                nombre_rock_ridge(e.get(inicio_uso..).unwrap_or(&[]))
                    .unwrap_or_else(|| String::from_utf8_lossy(crudo).to_string())
            };
            let nombre = nombre.split(';').next().unwrap_or("").trim_end_matches('.').to_string();
            entradas.push(Entrada {
                nombre,
                sector: u32::from_le_bytes(e[2..6].try_into().unwrap()),
                tamano: u32::from_le_bytes(e[10..14].try_into().unwrap()),
                es_dir: e[25] & 0x02 != 0,
            });
        }
        i += largo;
    }
    Ok(entradas)
}

/// Busca un archivo o carpeta por ruta ("casper/filesystem.squashfs"), sin importar mayúsculas.
fn buscar<R: Read + Seek>(r: &mut R, v: &Volumen, ruta: &str) -> Resultado<Option<Entrada>> {
    let mut actual = Entrada { nombre: String::new(), sector: v.raiz_sector, tamano: v.raiz_tamano, es_dir: true };
    for parte in ruta.split('/').filter(|p| !p.is_empty()) {
        if !actual.es_dir {
            return Ok(None);
        }
        let hijos = leer_directorio(r, actual.sector, actual.tamano, v.joliet)?;
        match hijos.into_iter().find(|h| h.nombre.eq_ignore_ascii_case(parte)) {
            Some(h) => actual = h,
            None => return Ok(None),
        }
    }
    Ok(Some(actual))
}

/// Revisa si la ISO es compatible con "Trae tu ISO": reconoce su familia y, si
/// `revisar_probada`, comprueba (por tamaño y SHA256) si es una de las ISOs probadas.
pub fn analizar<R: Read + Seek>(r: &mut R, nombre_archivo: &str, revisar_probada: bool) -> Resultado<InfoIso> {
    analizar_con(r, nombre_archivo, if revisar_probada { probadas() } else { &[] })
}

fn analizar_con<R: Read + Seek>(r: &mut R, nombre_archivo: &str, lista: &[Probada]) -> Resultado<InfoIso> {
    let tamano = r.seek(SeekFrom::End(0))?;
    if tamano > MAX_ISO {
        return Err(Error::Config(format!(
            "la ISO pesa {:.1} GB y el máximo es {:.1} GB",
            tamano as f64 / 1e9,
            MAX_ISO as f64 / 1e9
        )));
    }
    let v = volumen(r)?;

    // 1. Familia, por las señales de familias.json.
    let mut reconocida = None;
    'familias: for f in familias() {
        for a in &f.archivos {
            if buscar(r, &v, a)?.is_some() {
                reconocida = Some(f);
                break 'familias;
            }
        }
    }
    let Some(familia) = reconocida else {
        return Err(Error::Config(format!(
            "esta ISO no es compatible: Llevix no reconoce cómo está armada. Acepta ISOs como {}. Para otras distros, elige una del catálogo.",
            ejemplos_soportados()
        )));
    };
    if !familia.soportada {
        return Err(Error::Config(format!(
            "esta ISO es de la {} ({}). Llevix la reconoce, pero todavía no sabe instalarla: llegará en una próxima versión. Mientras tanto, elige una del catálogo o una ISO como {}.",
            familia.nombre,
            familia.ejemplos.join(", "),
            ejemplos_soportados()
        )));
    }

    // 2. Kernel donde lo guarda su familia.
    let mut tiene_kernel = false;
    for c in &familia.carpetas_kernel {
        if let Some(d) = buscar(r, &v, c)?.filter(|d| d.es_dir) {
            if leer_directorio(r, d.sector, d.tamano, v.joliet)?.iter().any(|e| e.nombre.to_ascii_lowercase().starts_with("vmlinuz")) {
                tiene_kernel = true;
                break;
            }
        }
    }
    if !tiene_kernel {
        return Err(Error::Config(format!("la ISO no trae el kernel donde lo guarda la {}", familia.nombre)));
    }
    let tipo = if buscar(r, &v, "casper/install-sources.yaml")?.is_some() { TipoIso::Capas } else { TipoIso::Squashfs };

    // 3. Nombre de la distro.
    let mut nombre = String::new();
    if let Some(info) = buscar(r, &v, ".disk/info")? {
        let mut buf = vec![0u8; (info.tamano as usize).min(512)];
        r.seek(SeekFrom::Start(info.sector as u64 * SECTOR_ISO))?;
        r.read_exact(&mut buf)?;
        nombre = String::from_utf8_lossy(&buf).lines().next().unwrap_or("").trim().to_string();
    }
    if nombre.is_empty() {
        nombre = nombre_archivo.to_string();
    }

    // 4. ¿Es una ISO probada? Solo se calcula el SHA256 si el tamaño coincide con alguna.
    let mut probada_como = None;
    let candidatas: Vec<&Probada> = lista.iter().filter(|p| p.tamano == tamano && p.familia == familia.id).collect();
    if !candidatas.is_empty() {
        r.seek(SeekFrom::Start(0))?;
        let mut suma = Sha256::new();
        let mut buf = vec![0u8; 4 * 1024 * 1024];
        loop {
            let n = r.read(&mut buf)?;
            if n == 0 {
                break;
            }
            suma.update(&buf[..n]);
        }
        let sha = hex::encode(suma.finalize());
        probada_como = candidatas.iter().find(|p| p.sha256.eq_ignore_ascii_case(&sha)).map(|p| p.nombre.clone());
    }
    Ok(InfoIso {
        nombre,
        tipo,
        tamano,
        familia: familia.id.clone(),
        nombre_familia: familia.nombre.clone(),
        nivel: if probada_como.is_some() { Nivel::Probada } else { Nivel::Familia },
        probada_como,
    })
}

/// Deja limpio el nombre de archivo para el encabezado (solo caracteres seguros).
fn nombre_seguro(n: &str) -> String {
    n.chars()
        .filter(|c| c.is_ascii_alphanumeric() || " ._()+-".contains(*c))
        .take(80)
        .collect()
}

/// Escribe el encabezado y la ISO en la zona reservada de la partición 4 del disco
/// (ya escrito con la imagen del instalador) y comprueba lo escrito.
pub fn escribir_iso<I, D>(
    iso: &mut I,
    nombre_archivo: &str,
    disco: &mut D,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(u64, u64),
) -> Resultado<()>
where
    I: Read + Seek,
    D: Read + Write + Seek,
{
    let tamano = iso.seek(SeekFrom::End(0))?;
    if tamano == 0 || tamano > MAX_ISO {
        return Err(Error::Config("la ISO no tiene un tamaño válido".into()));
    }
    let p4 = gpt::leer_particiones(disco)?
        .into_iter()
        .find(|p| p.numero == 4)
        .ok_or_else(|| Error::Gpt("no se encontró la partición del sistema".into()))?;
    if p4.tamano() < INICIO_RESERVA + ENCABEZADO + tamano {
        return Err(Error::Gpt("la partición del sistema es demasiado chica para la ISO".into()));
    }
    let base = p4.desplazamiento() + INICIO_RESERVA;

    // 1. SHA256 de la ISO.
    iso.seek(SeekFrom::Start(0))?;
    let mut suma = Sha256::new();
    let mut buf = vec![0u8; 4 * 1024 * 1024];
    let total = tamano * 3; // leer, escribir y verificar
    let mut hechos = 0u64;
    loop {
        if cancelar.load(Ordering::Relaxed) {
            return Err(Error::Cancelado);
        }
        let n = iso.read(&mut buf)?;
        if n == 0 {
            break;
        }
        suma.update(&buf[..n]);
        hechos += n as u64;
        progreso(hechos, total);
    }
    let sha = hex::encode(suma.finalize());

    // 2. La ISO, en trozos alineados a 512 bytes.
    iso.seek(SeekFrom::Start(0))?;
    disco.seek(SeekFrom::Start(base + ENCABEZADO))?;
    let mut restante = tamano;
    while restante > 0 {
        if cancelar.load(Ordering::Relaxed) {
            return Err(Error::Cancelado);
        }
        let n = restante.min(buf.len() as u64) as usize;
        iso.read_exact(&mut buf[..n])?;
        let alineado = n.div_ceil(512) * 512;
        buf[n..alineado].fill(0);
        disco.write_all(&buf[..alineado])?;
        restante -= n as u64;
        hechos += n as u64;
        progreso(hechos, total);
    }

    // 3. Comprobar lo escrito.
    disco.flush()?;
    disco.seek(SeekFrom::Start(base + ENCABEZADO))?;
    let mut verif = Sha256::new();
    let mut restante = tamano;
    while restante > 0 {
        if cancelar.load(Ordering::Relaxed) {
            return Err(Error::Cancelado);
        }
        let n = restante.min(buf.len() as u64) as usize;
        let alineado = n.div_ceil(512) * 512;
        disco.read_exact(&mut buf[..alineado])?;
        verif.update(&buf[..n]);
        restante -= n as u64;
        hechos += n as u64;
        progreso(hechos, total);
    }
    if hex::encode(verif.finalize()) != sha {
        return Err(Error::Verificacion("la ISO no se guardó bien en el disco".into()));
    }

    // 4. El encabezado va al final: sin él, el instalador no intenta usar una ISO a medias.
    let texto = format!(
        "LLEVIX-ISO 1\ntamano={tamano}\nsha256={sha}\nnombre={}\n",
        nombre_seguro(nombre_archivo)
    );
    let mut cabecera = vec![0u8; 4096];
    cabecera[..texto.len()].copy_from_slice(texto.as_bytes());
    disco.seek(SeekFrom::Start(base))?;
    disco.write_all(&cabecera)?;
    disco.flush()?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod pruebas {
    use super::*;
    use std::io::Cursor;

    /// Arma una ISO 9660 mínima con nombres Joliet y los archivos dados (ruta, contenido).
    /// Solo admite carpetas de un nivel, que alcanza para casper/… y .disk/….
    pub fn iso_de_prueba(archivos: &[(&str, &[u8])]) -> Vec<u8> {
        const S: usize = 2048;
        let mut iso = vec![0u8; S * 16];
        // Sectores: 16 primario, 17 Joliet, 18 terminador, 19 raíz, 20.. carpetas, luego datos.
        let mut carpetas: Vec<String> = archivos
            .iter()
            .filter_map(|(r, _)| r.split_once('/').map(|(c, _)| c.to_string()))
            .collect();
        carpetas.sort();
        carpetas.dedup();
        let sector_carpeta = |i: usize| 20 + i;
        let mut sector_dato = 20 + carpetas.len();
        let mut ubic: Vec<(String, usize, usize)> = Vec::new(); // ruta, sector, tamaño
        for (r, d) in archivos {
            ubic.push((r.to_string(), sector_dato, d.len()));
            sector_dato += d.len().div_ceil(S).max(1);
        }

        let registro = |nombre: &[u8], sector: usize, tamano: usize, dir: bool| -> Vec<u8> {
            let mut e = vec![0u8; 33 + nombre.len() + (1 - nombre.len() % 2)];
            e[0] = e.len() as u8;
            e[2..6].copy_from_slice(&(sector as u32).to_le_bytes());
            e[10..14].copy_from_slice(&(tamano as u32).to_le_bytes());
            e[25] = if dir { 2 } else { 0 };
            e[32] = nombre.len() as u8;
            e[33..33 + nombre.len()].copy_from_slice(nombre);
            e
        };
        let ucs2 = |s: &str| -> Vec<u8> { s.encode_utf16().flat_map(|c| c.to_be_bytes()).collect() };
        let directorio = |entradas: Vec<Vec<u8>>| -> Vec<u8> {
            let mut d = registro(&[0], 0, S, true);
            d.extend(registro(&[1], 0, S, true));
            for e in entradas {
                d.extend(e);
            }
            d.resize(S, 0);
            d
        };

        let raiz = {
            let mut ent: Vec<Vec<u8>> = carpetas.iter().enumerate().map(|(i, c)| registro(&ucs2(c), sector_carpeta(i), S, true)).collect();
            for (r, s, t) in &ubic {
                if !r.contains('/') {
                    ent.push(registro(&ucs2(r), *s, *t, false));
                }
            }
            directorio(ent)
        };
        let mut pvd = vec![0u8; S];
        pvd[0] = 1;
        pvd[1..6].copy_from_slice(b"CD001");
        pvd[156..190].copy_from_slice(&registro(&[0], 19, S, true)[..34]);
        let mut svd = pvd.clone();
        svd[0] = 2;
        svd[88..91].copy_from_slice(&[0x25, 0x2F, 0x45]);
        let mut fin = vec![0u8; S];
        fin[0] = 255;
        fin[1..6].copy_from_slice(b"CD001");
        iso.extend(pvd);
        iso.extend(svd);
        iso.extend(fin);
        iso.extend(raiz);
        for c in &carpetas {
            let ent = ubic
                .iter()
                .filter_map(|(r, s, t)| {
                    let (dir, archivo) = r.split_once('/')?;
                    (dir == c).then(|| registro(&ucs2(archivo), *s, *t, false))
                })
                .collect();
            iso.extend(directorio(ent));
        }
        for (_, d) in archivos {
            let mut bloque = d.to_vec();
            bloque.resize(d.len().div_ceil(S).max(1) * S, 0);
            iso.extend(bloque);
        }
        iso
    }

    #[test]
    fn reconoce_una_iso_con_squashfs() {
        let iso = iso_de_prueba(&[
            (".disk/info", b"Linux Mint 22.3 \"Zena\" - Release amd64\n"),
            ("casper/filesystem.squashfs", b"squashfs"),
            ("casper/vmlinuz", b"kernel"),
        ]);
        let info = analizar(&mut Cursor::new(iso), "mint.iso", true).unwrap();
        assert_eq!(info.tipo, TipoIso::Squashfs);
        assert_eq!(info.familia, "casper");
        assert_eq!(info.nivel, Nivel::Familia);
        assert_eq!(info.nombre, "Linux Mint 22.3 \"Zena\" - Release amd64");
    }

    #[test]
    fn reconoce_una_iso_en_capas() {
        let iso = iso_de_prueba(&[
            ("casper/install-sources.yaml", b"- default: true\n  path: minimal.standard.squashfs\n"),
            ("casper/minimal.squashfs", b"x"),
            ("casper/vmlinuz", b"k"),
        ]);
        let info = analizar(&mut Cursor::new(iso), "ubuntu.iso", false).unwrap();
        assert_eq!(info.tipo, TipoIso::Capas);
        assert_eq!(info.nombre, "ubuntu.iso");
    }

    #[test]
    fn reconoce_familias_que_todavia_no_instala() {
        let fedora = iso_de_prueba(&[("LiveOS/squashfs.img", b"x"), ("isolinux/vmlinuz", b"k")]);
        let r = analizar(&mut Cursor::new(fedora), "fedora.iso", true);
        assert!(matches!(r, Err(Error::Config(ref m)) if m.contains("familia Fedora") && m.contains("todavía no")), "{r:?}");
        let debian = iso_de_prueba(&[("live/filesystem.squashfs", b"x"), ("live/vmlinuz", b"k")]);
        let r = analizar(&mut Cursor::new(debian), "debian.iso", true);
        assert!(matches!(r, Err(Error::Config(ref m)) if m.contains("familia Debian")), "{r:?}");
    }

    #[test]
    fn rechaza_isos_no_compatibles() {
        let rara = iso_de_prueba(&[("boot/kernel", b"x")]);
        let r = analizar(&mut Cursor::new(rara), "rara.iso", true);
        assert!(matches!(r, Err(Error::Config(ref m)) if m.contains("no es compatible") && m.contains("Ubuntu")), "{r:?}");
        assert!(analizar(&mut Cursor::new(vec![0u8; 100_000]), "x.iso", true).is_err());
        // Familia correcta pero sin kernel.
        let sin_kernel = iso_de_prueba(&[("casper/filesystem.squashfs", b"x")]);
        assert!(analizar(&mut Cursor::new(sin_kernel), "x.iso", true).is_err());
    }

    #[test]
    fn reconoce_una_iso_probada_por_tamano_y_sha256() {
        let iso = iso_de_prueba(&[("casper/filesystem.squashfs", b"squashfs"), ("casper/vmlinuz", b"kernel")]);
        let sha = hex::encode(Sha256::digest(&iso));
        let lista = vec![Probada { nombre: "Prueba 1.0".into(), familia: "casper".into(), tamano: iso.len() as u64, sha256: sha }];
        let info = analizar_con(&mut Cursor::new(iso.clone()), "p.iso", &lista).unwrap();
        assert_eq!(info.nivel, Nivel::Probada);
        assert_eq!(info.probada_como.as_deref(), Some("Prueba 1.0"));
        // Mismo tamaño, otro contenido: no es la probada.
        let mut otra = iso.clone();
        *otra.last_mut().unwrap() ^= 1;
        assert_eq!(analizar_con(&mut Cursor::new(otra), "p.iso", &lista).unwrap().nivel, Nivel::Familia);
    }

    #[test]
    fn familias_y_probadas_son_validas() {
        let f = familias();
        assert!(f.iter().any(|x| x.soportada));
        let mut ids: Vec<&str> = f.iter().map(|x| x.id.as_str()).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), f.len(), "ids repetidos en familias.json");
        for x in f {
            assert!(!x.archivos.is_empty() && !x.carpetas_kernel.is_empty() && !x.ejemplos.is_empty(), "{}", x.id);
            for a in x.archivos.iter().chain(&x.carpetas_kernel) {
                assert!(!a.starts_with('/') && !a.contains("..") && !a.is_empty(), "ruta no válida: {a}");
            }
        }
        for p in probadas() {
            assert!(ids.contains(&p.familia.as_str()), "familia desconocida: {}", p.familia);
            assert!(p.sha256.len() == 64 && p.sha256.chars().all(|c| c.is_ascii_hexdigit()), "{}", p.nombre);
            assert!(p.tamano > 0 && p.tamano <= MAX_ISO, "{}", p.nombre);
        }
    }

    #[test]
    fn escribe_la_iso_en_la_zona_reservada() {
        use crate::gpt::pruebas::escribir_gpt;
        // Disco simulado chico: se simula una partición 4 enorme sin ocupar memoria,
        // con un archivo disperso.
        let archivo = tempfile::NamedTempFile::new().unwrap();
        let p4_inicio = 2048u64;
        let p4_fin = p4_inicio + (24u64 << 30) / 512 - 1;
        let mut cab = vec![0u8; 64 * 1024];
        let linux = [0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4];
        escribir_gpt(&mut cab, &[([1; 16], "LLEVIX-DATOS", 10, 20), ([2; 16], "BIOS", 21, 22), ([3; 16], "EFI", 23, 24), (linux, "LLEVIX-SISTEMA", p4_inicio, p4_fin)]);
        {
            let f = archivo.as_file();
            f.set_len((p4_fin + 1) * 512 + 1024 * 1024).unwrap();
            let mut w = f;
            w.write_all(&cab).unwrap();
        }
        let mut disco = std::fs::OpenOptions::new().read(true).write(true).open(archivo.path()).unwrap();
        let iso: Vec<u8> = (0..3 * 2048 * 1000u32).map(|i| (i % 251) as u8).collect();
        escribir_iso(&mut Cursor::new(iso.clone()), "mi distro.iso", &mut disco, &AtomicBool::new(false), &mut |_, _| {}).unwrap();

        let base = p4_inicio * 512 + INICIO_RESERVA;
        let mut cabecera = vec![0u8; 4096];
        disco.seek(SeekFrom::Start(base)).unwrap();
        disco.read_exact(&mut cabecera).unwrap();
        let texto = String::from_utf8_lossy(&cabecera).trim_end_matches('\0').to_string();
        assert!(texto.starts_with("LLEVIX-ISO 1\n"), "{texto}");
        assert!(texto.contains(&format!("tamano={}\n", iso.len())));
        assert!(texto.contains(&format!("sha256={}\n", hex::encode(Sha256::digest(&iso)))));
        assert!(texto.contains("nombre=mi distro.iso\n"));
        let mut leida = vec![0u8; iso.len()];
        disco.seek(SeekFrom::Start(base + ENCABEZADO)).unwrap();
        disco.read_exact(&mut leida).unwrap();
        assert_eq!(leida, iso);
    }
}
