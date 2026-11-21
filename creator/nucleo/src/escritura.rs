//! Escritura de la imagen en el disco destino.
//!
//! - Descomprime zstd mientras lee (sin archivos temporales grandes).
//! - Escribe solo los rangos con datos que indica el `.bmap`.
//! - Comprueba la SHA256 de cada rango ANTES de escribirlo (si la descarga estuviera
//!   dañada, se detiene) y, al final, vuelve a leer lo escrito y lo compara.
//!
//! El destino es cualquier cosa que se pueda leer, escribir y posicionar: en las pruebas
//! un archivo (disco simulado) y en Windows el disco físico (`\\.\PhysicalDriveN`).
//! Todas las escrituras empiezan y terminan en múltiplos de 512 bytes, como exigen los
//! discos físicos.

use crate::bmap::{Bmap, Rango};
use crate::error::{Error, Resultado};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};

/// Tamaño de cada trozo que se lee y se escribe (4 MiB).
const TROZO: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Fase {
    Escribiendo,
    Verificando,
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
pub struct Progreso {
    pub fase: Fase,
    pub hechos: u64,
    pub total: u64,
}

/// Escribe la imagen comprimida `zst` en `destino` según `bmap`, y luego verifica.
pub fn escribir_y_verificar<R, D>(
    zst: R,
    bmap: &Bmap,
    destino: &mut D,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(Progreso),
) -> Resultado<()>
where
    R: Read,
    D: Read + Write + Seek,
{
    escribir(zst, bmap, destino, cancelar, progreso)?;
    verificar(bmap, destino, cancelar, progreso)
}

/// Escribe sin verificar al final (la verificación es [`verificar`]).
pub fn escribir<R, D>(
    zst: R,
    bmap: &Bmap,
    destino: &mut D,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(Progreso),
) -> Resultado<()>
where
    R: Read,
    D: Write + Seek,
{
    if bmap.tamano_bloque % 512 != 0 {
        return Err(Error::Bmap("el tamaño de bloque no es múltiplo de 512".into()));
    }
    let mut lector = zstd::stream::read::Decoder::new(zst)?;
    // Admite imágenes comprimidas con ventanas grandes (zstd --long).
    lector.window_log_max(31)?;

    let total = bmap.bytes_con_datos();
    let mut hechos = 0u64;
    let mut posicion = 0u64; // posición actual en la imagen descomprimida
    let mut buffer = vec![0u8; TROZO];

    for rango in &bmap.rangos {
        let inicio = rango.desplazamiento(bmap.tamano_bloque);
        let longitud = bmap.longitud_rango(rango);

        // Salta los bytes sin datos que hay antes del rango.
        saltar(&mut lector, inicio - posicion, &mut buffer)?;
        posicion = inicio;

        destino.seek(SeekFrom::Start(inicio))?;
        let mut suma = Sha256::new();
        let mut restante = longitud;
        while restante > 0 {
            if cancelar.load(Ordering::Relaxed) {
                return Err(Error::Cancelado);
            }
            let n = restante.min(TROZO as u64) as usize;
            lector.read_exact(&mut buffer[..n]).map_err(|e| {
                if e.kind() == io::ErrorKind::UnexpectedEof {
                    Error::Integridad("la imagen terminó antes de lo esperado".into())
                } else {
                    Error::Io(e)
                }
            })?;
            suma.update(&buffer[..n]);
            // Un disco físico solo acepta múltiplos de 512: el último trozo de una
            // imagen de tamaño raro se completa con ceros.
            let n_alineado = n.div_ceil(512) * 512;
            buffer[n..n_alineado].fill(0);
            destino.write_all(&buffer[..n_alineado])?;
            restante -= n as u64;
            posicion += n as u64;
            hechos += n as u64;
            progreso(Progreso { fase: Fase::Escribiendo, hechos, total });
        }
        comprobar_suma(rango, suma, "al leer la imagen descargada", Error::Integridad)?;
    }
    destino.flush()?;
    Ok(())
}

/// Vuelve a leer del destino cada rango escrito y compara su SHA256 con el `.bmap`.
pub fn verificar<D>(
    bmap: &Bmap,
    destino: &mut D,
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(Progreso),
) -> Resultado<()>
where
    D: Read + Seek,
{
    let total = bmap.bytes_con_datos();
    let mut hechos = 0u64;
    let mut buffer = vec![0u8; TROZO];
    for rango in &bmap.rangos {
        if rango.sha256.is_none() {
            continue;
        }
        let longitud = bmap.longitud_rango(rango);
        destino.seek(SeekFrom::Start(rango.desplazamiento(bmap.tamano_bloque)))?;
        let mut suma = Sha256::new();
        let mut restante = longitud;
        while restante > 0 {
            if cancelar.load(Ordering::Relaxed) {
                return Err(Error::Cancelado);
            }
            let n = restante.min(TROZO as u64) as usize;
            let n_alineado = n.div_ceil(512) * 512;
            destino.read_exact(&mut buffer[..n_alineado])?;
            suma.update(&buffer[..n]);
            restante -= n as u64;
            hechos += n as u64;
            progreso(Progreso { fase: Fase::Verificando, hechos, total });
        }
        comprobar_suma(rango, suma, "en el disco", Error::Verificacion)?;
    }
    Ok(())
}

fn comprobar_suma(
    rango: &Rango,
    suma: Sha256,
    donde: &str,
    tipo: fn(String) -> Error,
) -> Resultado<()> {
    if let Some(esperada) = rango.sha256 {
        let real: [u8; 32] = suma.finalize().into();
        if real != esperada {
            return Err(tipo(format!(
                "los bloques {}-{} no coinciden {donde}",
                rango.primer_bloque, rango.ultimo_bloque
            )));
        }
    }
    Ok(())
}

fn saltar<R: Read>(lector: &mut R, mut bytes: u64, buffer: &mut [u8]) -> Resultado<()> {
    while bytes > 0 {
        let n = bytes.min(buffer.len() as u64) as usize;
        lector.read_exact(&mut buffer[..n]).map_err(|e| {
            if e.kind() == io::ErrorKind::UnexpectedEof {
                Error::Integridad("la imagen terminó antes de lo esperado".into())
            } else {
                Error::Io(e)
            }
        })?;
        bytes -= n as u64;
    }
    Ok(())
}

#[cfg(test)]
mod pruebas {
    use super::*;
    use crate::bmap::pruebas::crear_bmap;
    use std::fs::OpenOptions;
    use std::io::Cursor;

    /// Imagen de prueba: zonas con datos y zonas vacías, tamaño no múltiplo del bloque.
    fn imagen_de_prueba() -> Vec<u8> {
        let mut img = vec![0u8; 4096 * 300 + 1024];
        for (i, b) in img[..4096 * 3].iter_mut().enumerate() {
            *b = (i % 251) as u8 + 1;
        }
        for (i, b) in img[4096 * 100..4096 * 180].iter_mut().enumerate() {
            *b = (i % 13) as u8 + 7;
        }
        let largo = img.len();
        img[largo - 10] = 9; // último bloque parcial
        img
    }

    fn comprimir(datos: &[u8]) -> Vec<u8> {
        zstd::stream::encode_all(Cursor::new(datos), 3).unwrap()
    }

    #[test]
    fn escribe_solo_los_bloques_con_datos_y_verifica() {
        let img = imagen_de_prueba();
        let bmap = Bmap::leer(&crear_bmap(&img, 4096)).unwrap();
        let zst = comprimir(&img);

        // Disco simulado: un archivo lleno de 0xAA (como un disco con datos viejos).
        let archivo = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(archivo.path(), vec![0xAAu8; img.len() + 4096]).unwrap();
        let mut destino = OpenOptions::new().read(true).write(true).open(archivo.path()).unwrap();

        let cancelar = AtomicBool::new(false);
        let mut ultimo = None;
        escribir_y_verificar(Cursor::new(zst), &bmap, &mut destino, &cancelar, &mut |p| {
            ultimo = Some(p)
        })
        .unwrap();
        let p = ultimo.unwrap();
        assert_eq!(p.fase, Fase::Verificando);
        assert_eq!(p.hechos, p.total);

        let escrito = std::fs::read(archivo.path()).unwrap();
        // Los rangos con datos quedaron idénticos a la imagen.
        for r in &bmap.rangos {
            let ini = (r.primer_bloque * 4096) as usize;
            let fin = (((r.ultimo_bloque + 1) * 4096) as usize).min(img.len());
            assert_eq!(&escrito[ini..fin], &img[ini..fin]);
        }
        // Lo que no tenía datos no se tocó (sigue con 0xAA).
        assert!(escrito[4096 * 50..4096 * 60].iter().all(|&b| b == 0xAA));
    }

    #[test]
    fn se_detiene_si_la_imagen_esta_danada() {
        let img = imagen_de_prueba();
        let bmap = Bmap::leer(&crear_bmap(&img, 4096)).unwrap();
        let mut danada = img.clone();
        danada[4096 * 120] ^= 0xFF; // un byte cambiado dentro de un rango
        let zst = comprimir(&danada);
        let mut destino = Cursor::new(vec![0u8; img.len() + 4096]);
        let cancelar = AtomicBool::new(false);
        let r = escribir(Cursor::new(zst), &bmap, &mut destino, &cancelar, &mut |_| {});
        assert!(matches!(r, Err(Error::Integridad(_))), "{r:?}");
    }

    #[test]
    fn la_verificacion_detecta_un_disco_que_no_guardo_bien() {
        let img = imagen_de_prueba();
        let bmap = Bmap::leer(&crear_bmap(&img, 4096)).unwrap();
        let mut destino = Cursor::new(vec![0u8; img.len() + 4096]);
        let cancelar = AtomicBool::new(false);
        escribir(Cursor::new(comprimir(&img)), &bmap, &mut destino, &cancelar, &mut |_| {}).unwrap();
        destino.get_mut()[4096 * 2 + 7] ^= 1; // el "disco" corrompe un byte
        let r = verificar(&bmap, &mut destino, &cancelar, &mut |_| {});
        assert!(matches!(r, Err(Error::Verificacion(_))), "{r:?}");
    }

    #[test]
    fn se_puede_cancelar() {
        let img = imagen_de_prueba();
        let bmap = Bmap::leer(&crear_bmap(&img, 4096)).unwrap();
        let mut destino = Cursor::new(vec![0u8; img.len() + 4096]);
        let cancelar = AtomicBool::new(true);
        let r = escribir(Cursor::new(comprimir(&img)), &bmap, &mut destino, &cancelar, &mut |_| {});
        assert!(matches!(r, Err(Error::Cancelado)));
    }

    #[test]
    fn escribe_siempre_en_multiplos_de_512() {
        /// Destino que falla si se escribe o se posiciona fuera de múltiplos de 512.
        struct DiscoEstricto(Cursor<Vec<u8>>);
        impl Write for DiscoEstricto {
            fn write(&mut self, b: &[u8]) -> io::Result<usize> {
                assert_eq!(b.len() % 512, 0, "escritura de {} bytes", b.len());
                assert_eq!(self.0.position() % 512, 0);
                self.0.write(b)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        impl Seek for DiscoEstricto {
            fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
                let r = self.0.seek(p)?;
                assert_eq!(r % 512, 0);
                Ok(r)
            }
        }
        let img = imagen_de_prueba();
        let bmap = Bmap::leer(&crear_bmap(&img, 4096)).unwrap();
        let mut destino = DiscoEstricto(Cursor::new(vec![0u8; img.len() + 4096]));
        let cancelar = AtomicBool::new(false);
        escribir(Cursor::new(comprimir(&img)), &bmap, &mut destino, &cancelar, &mut |_| {}).unwrap();
    }
}
