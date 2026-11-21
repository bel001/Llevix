//! Descarga de la imagen con reanudación y verificación SHA256.
//!
//! - Cada parte se guarda en la carpeta de caché. Si la descarga se corta, la próxima
//!   vez continúa desde donde quedó (cabecera HTTP `Range`).
//! - Cada parte se comprueba con su SHA256; una parte dañada se borra y se informa.
//! - Al final se comprueba la SHA256 de la imagen completa (todas las partes unidas).
//! - [`abrir_imagen`] devuelve un lector que recorre las partes en orden, sin unirlas
//!   en un archivo nuevo (no ocupa el doble de espacio).

use crate::error::{Error, Resultado};
use crate::manifest::Parte;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

#[derive(Debug, Clone, Copy, serde::Serialize)]
pub struct ProgresoDescarga {
    pub hechos: u64,
    pub total: u64,
    /// true mientras se comprueban las sumas (sin red).
    pub verificando: bool,
}

/// SHA256 en hexadecimal de unos bytes en memoria (por ejemplo, el .bmap).
pub fn sha256_hex(datos: &[u8]) -> String {
    hex::encode(Sha256::digest(datos))
}

/// Rutas de las partes de una variante dentro de la carpeta de caché.
pub fn rutas_partes(cache: &Path, id: &str, partes: &[Parte]) -> Vec<PathBuf> {
    (0..partes.len())
        .map(|i| cache.join(format!("llevix-{id}.img.zst.parte{:03}", i + 1)))
        .collect()
}

fn sha256_archivo(ruta: &Path, cancelar: &AtomicBool, avance: &mut dyn FnMut(u64)) -> Resultado<String> {
    let mut f = File::open(ruta)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if cancelar.load(Ordering::Relaxed) {
            return Err(Error::Cancelado);
        }
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        avance(n as u64);
    }
    Ok(hex::encode(h.finalize()))
}

fn cliente() -> Resultado<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .user_agent(concat!("llevix-creador/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(20))
        .timeout(None)
        .build()
        .map_err(|e| Error::Descarga(e.to_string()))
}

/// Descarga un texto pequeño (manifest.json, .bmap).
pub fn descargar_texto(url: &str) -> Resultado<String> {
    let r = cliente()?
        .get(url)
        .timeout(Duration::from_secs(60))
        .send()
        .map_err(|e| Error::Descarga(format!("{url}: {e}")))?;
    if !r.status().is_success() {
        return Err(Error::Descarga(format!("{url}: respuesta {}", r.status())));
    }
    r.text().map_err(|e| Error::Descarga(e.to_string()))
}

/// Descarga una parte a `ruta`, continuando si ya hay un trozo descargado.
fn descargar_parte(
    cliente: &reqwest::blocking::Client,
    parte: &Parte,
    ruta: &Path,
    cancelar: &AtomicBool,
    avance: &mut dyn FnMut(u64),
) -> Resultado<()> {
    let ya = fs::metadata(ruta).map(|m| m.len()).unwrap_or(0);
    if ya > parte.tamano {
        fs::remove_file(ruta)?;
        return descargar_parte(cliente, parte, ruta, cancelar, avance);
    }
    avance(ya);
    if ya == parte.tamano {
        return Ok(());
    }

    let mut peticion = cliente.get(&parte.url);
    if ya > 0 {
        peticion = peticion.header(reqwest::header::RANGE, format!("bytes={ya}-"));
    }
    let mut respuesta = peticion.send().map_err(|e| Error::Descarga(format!("{}: {e}", parte.url)))?;
    let status = respuesta.status();
    let mut archivo = if ya > 0 && status == reqwest::StatusCode::PARTIAL_CONTENT {
        OpenOptions::new().append(true).open(ruta)?
    } else if status.is_success() {
        // El servidor no aceptó continuar: se empieza de nuevo.
        if ya > 0 {
            avance(0u64.wrapping_sub(ya));
        }
        File::create(ruta)?
    } else {
        return Err(Error::Descarga(format!("{}: respuesta {status}", parte.url)));
    };

    let mut buf = vec![0u8; 256 * 1024];
    loop {
        if cancelar.load(Ordering::Relaxed) {
            archivo.flush()?;
            return Err(Error::Cancelado);
        }
        let n = respuesta.read(&mut buf).map_err(|e| Error::Descarga(e.to_string()))?;
        if n == 0 {
            break;
        }
        archivo.write_all(&buf[..n])?;
        avance(n as u64);
    }
    archivo.flush()?;
    let final_ = fs::metadata(ruta)?.len();
    if final_ != parte.tamano {
        return Err(Error::Descarga(format!(
            "la descarga se cortó ({final_} de {} bytes); vuelve a intentarlo para continuar",
            parte.tamano
        )));
    }
    Ok(())
}

/// Descarga (o reanuda) todas las partes y verifica sus sumas y la suma total.
pub fn descargar_imagen(
    cache: &Path,
    id: &str,
    partes: &[Parte],
    sha256_total: &str,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(ProgresoDescarga),
) -> Resultado<Vec<PathBuf>> {
    fs::create_dir_all(cache)?;
    let rutas = rutas_partes(cache, id, partes);
    let total: u64 = partes.iter().map(|p| p.tamano).sum();
    let cliente = cliente()?;

    let mut hechos = 0u64;
    for (parte, ruta) in partes.iter().zip(&rutas) {
        let base = hechos;
        let mut en_parte = 0u64;
        descargar_parte(&cliente, parte, ruta, cancelar, &mut |n| {
            en_parte = en_parte.wrapping_add(n);
            progreso(ProgresoDescarga { hechos: base + en_parte, total, verificando: false });
        })?;
        hechos += parte.tamano;
    }

    // Verificación: cada parte y la imagen completa.
    let mut total_hash = Sha256::new();
    let mut verificados = 0u64;
    for (parte, ruta) in partes.iter().zip(&rutas) {
        let mut f = File::open(ruta)?;
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            if cancelar.load(Ordering::Relaxed) {
                return Err(Error::Cancelado);
            }
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
            total_hash.update(&buf[..n]);
            verificados += n as u64;
            progreso(ProgresoDescarga { hechos: verificados, total, verificando: true });
        }
        if hex::encode(h.finalize()) != parte.sha256.to_ascii_lowercase() {
            fs::remove_file(ruta)?;
            return Err(Error::Integridad(
                "una parte de la descarga está dañada; se borró para descargarla de nuevo".into(),
            ));
        }
    }
    if hex::encode(total_hash.finalize()) != sha256_total.to_ascii_lowercase() {
        return Err(Error::Integridad("la suma SHA256 de la imagen no coincide".into()));
    }
    Ok(rutas)
}

/// Comprueba la SHA256 de un archivo ya descargado.
pub fn verificar_archivo(ruta: &Path, sha256: &str, cancelar: &AtomicBool) -> Resultado<()> {
    let real = sha256_archivo(ruta, cancelar, &mut |_| {})?;
    if real != sha256.to_ascii_lowercase() {
        return Err(Error::Integridad(format!("{} no coincide con su SHA256", ruta.display())));
    }
    Ok(())
}

/// Lector que recorre las partes en orden como si fueran un solo archivo.
pub fn abrir_imagen(rutas: &[PathBuf]) -> Resultado<Box<dyn Read + Send>> {
    let mut lector: Box<dyn Read + Send> = Box::new(io::empty());
    for r in rutas {
        lector = Box::new(lector.chain(File::open(r)?));
    }
    Ok(lector)
}

#[cfg(test)]
mod pruebas {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    /// Servidor HTTP mínimo que sirve archivos en memoria y respeta `Range`.
    /// Si `cortar` > 0, la primera respuesta se corta en ese byte.
    fn servidor(archivos: Vec<(&'static str, Vec<u8>)>, cortar: usize) -> (String, Arc<Mutex<Vec<String>>>) {
        let escucha = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", escucha.local_addr().unwrap());
        let registro = Arc::new(Mutex::new(Vec::new()));
        let reg = registro.clone();
        thread::spawn(move || {
            let mut cortados = std::collections::HashSet::new();
            for flujo in escucha.incoming() {
                let mut flujo = flujo.unwrap();
                let mut lector = BufReader::new(flujo.try_clone().unwrap());
                let mut primera = String::new();
                lector.read_line(&mut primera).unwrap();
                let ruta = primera.split_whitespace().nth(1).unwrap_or("/").to_string();
                let mut desde = 0usize;
                loop {
                    let mut l = String::new();
                    lector.read_line(&mut l).unwrap();
                    if l.trim().is_empty() {
                        break;
                    }
                    if let Some(v) = l.to_ascii_lowercase().strip_prefix("range: bytes=") {
                        desde = v.trim().trim_end_matches('-').parse().unwrap();
                    }
                }
                reg.lock().unwrap().push(format!("{ruta} desde {desde}"));
                let Some((_, datos)) = archivos.iter().find(|(n, _)| ruta == format!("/{n}")) else {
                    write!(flujo, "HTTP/1.1 404 No\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                    continue;
                };
                let cuerpo = &datos[desde..];
                // Solo se corta la primera respuesta del servidor.
                let (codigo, cuerpo) = if cortar > 0 && cortados.is_empty() && cortados.insert(ruta.clone()) {
                    (if desde > 0 { "206 Partial" } else { "200 OK" }, &cuerpo[..cortar.min(cuerpo.len())])
                } else {
                    (if desde > 0 { "206 Partial" } else { "200 OK" }, cuerpo)
                };
                // Se anuncia el largo completo: si se corta, el cliente lo nota.
                let anunciado = datos.len() - desde;
                let _ = write!(
                    flujo,
                    "HTTP/1.1 {codigo}\r\nContent-Length: {anunciado}\r\nConnection: close\r\n\r\n"
                );
                let _ = flujo.write_all(cuerpo);
            }
        });
        (base, registro)
    }

    fn sha(d: &[u8]) -> String {
        hex::encode(Sha256::digest(d))
    }

    #[test]
    fn descarga_partes_reanuda_y_verifica() {
        let a: Vec<u8> = (0..300_000u32).map(|i| (i % 255) as u8).collect();
        let b: Vec<u8> = (0..123_456u32).map(|i| (i % 7) as u8).collect();
        let (base, registro) = servidor(vec![("a", a.clone()), ("b", b.clone())], 100_000);
        let partes = vec![
            Parte { url: format!("{base}/a"), tamano: a.len() as u64, sha256: sha(&a) },
            Parte { url: format!("{base}/b"), tamano: b.len() as u64, sha256: sha(&b) },
        ];
        let total = sha(&[a.clone(), b.clone()].concat());
        let cache = tempfile::tempdir().unwrap();
        let cancelar = AtomicBool::new(false);

        // Primer intento: la conexión se corta a los 100 000 bytes.
        let r = descargar_imagen(cache.path(), "x", &partes, &total, &cancelar, &mut |_| {});
        assert!(matches!(r, Err(Error::Descarga(_))), "{r:?}");

        // Segundo intento: continúa desde donde quedó (Range) y termina.
        let mut ultimo = None;
        let rutas = descargar_imagen(cache.path(), "x", &partes, &total, &cancelar, &mut |p| ultimo = Some(p)).unwrap();
        assert!(ultimo.unwrap().verificando);
        assert!(registro.lock().unwrap().iter().any(|l| l == "/a desde 100000"), "{:?}", registro.lock().unwrap());

        let mut unido = Vec::new();
        abrir_imagen(&rutas).unwrap().read_to_end(&mut unido).unwrap();
        assert_eq!(unido, [a, b].concat());
    }

    #[test]
    fn detecta_una_parte_danada() {
        let a = vec![1u8; 5000];
        let (base, _) = servidor(vec![("a", a.clone())], 0);
        let partes = vec![Parte { url: format!("{base}/a"), tamano: 5000, sha256: sha(&[2u8; 5000]) }];
        let cache = tempfile::tempdir().unwrap();
        let r = descargar_imagen(cache.path(), "x", &partes, &sha(&a), &AtomicBool::new(false), &mut |_| {});
        assert!(matches!(r, Err(Error::Integridad(_))), "{r:?}");
        // La parte dañada se borró para no reutilizarla.
        assert!(!rutas_partes(cache.path(), "x", &partes)[0].exists());
    }
}
