//! El proceso completo de escritura de un disco, en el orden correcto.
//!
//! Por qué la tabla de particiones se escribe AL FINAL:
//! Windows vigila el comienzo del disco. Si ve aparecer una tabla de particiones nueva
//! mientras todavía estamos escribiendo, detecta las particiones (por ejemplo la exFAT
//! LLEVIX), las monta y desde ese momento bloquea las escrituras dentro de ellas
//! ("Acceso denegado", os error 5). Por eso el primer MiB del disco (MBR protector y
//! GPT) se guarda en memoria con [`CabeceraDiferida`] y se escribe recién cuando todo lo
//! demás (imagen verificada, ISO propia y llevix-config.json) ya está en el disco. Hasta entonces,
//! para Windows el disco está vacío y no hay nada que montar.
//!
//! El mismo código se usa con un disco real (Windows) y con un archivo (pruebas en
//! Linux y prueba de punta a punta con QEMU).

use crate::bmap::Bmap;
use crate::error::{Error, Resultado};
use crate::{esp, escritura, iso};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::sync::atomic::AtomicBool;

/// Bytes del comienzo del disco que se escriben al final (MBR protector + GPT principal
/// caben en los primeros 17 KiB; las particiones de Llevix empiezan en 1 MiB).
pub const TAM_CABECERA: u64 = 1024 * 1024;

/// Envoltorio de un disco que guarda en memoria lo que se escribe en el primer MiB y
/// lo devuelve al leer. El resto pasa directo al disco. [`CabeceraDiferida::confirmar`]
/// escribe esa memoria en el disco.
pub struct CabeceraDiferida<'a, D> {
    disco: &'a mut D,
    cabecera: Vec<u8>,
    posicion: u64,
}

impl<'a, D: Read + Write + Seek> CabeceraDiferida<'a, D> {
    pub fn new(disco: &'a mut D) -> Self {
        CabeceraDiferida { disco, cabecera: vec![0u8; TAM_CABECERA as usize], posicion: 0 }
    }

    /// Escribe el primer MiB guardado en memoria, vacía los búferes del disco y
    /// comprueba lo escrito leyéndolo de nuevo.
    pub fn confirmar(self) -> Resultado<()> {
        self.disco.seek(SeekFrom::Start(0))?;
        self.disco.write_all(&self.cabecera)?;
        self.disco.flush()?;
        let mut leido = vec![0u8; TAM_CABECERA as usize];
        self.disco.seek(SeekFrom::Start(0))?;
        self.disco.read_exact(&mut leido)?;
        if leido != self.cabecera {
            return Err(Error::Verificacion("la tabla de particiones no se guardó bien".into()));
        }
        Ok(())
    }
}

impl<D: Read + Write + Seek> Read for CabeceraDiferida<'_, D> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let n = if self.posicion < TAM_CABECERA {
            let ini = self.posicion as usize;
            let n = buf.len().min(TAM_CABECERA as usize - ini);
            buf[..n].copy_from_slice(&self.cabecera[ini..ini + n]);
            n
        } else {
            self.disco.seek(SeekFrom::Start(self.posicion))?;
            self.disco.read(buf)?
        };
        self.posicion += n as u64;
        Ok(n)
    }
}

impl<D: Read + Write + Seek> Write for CabeceraDiferida<'_, D> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let n = if self.posicion < TAM_CABECERA {
            let ini = self.posicion as usize;
            let n = buf.len().min(TAM_CABECERA as usize - ini);
            self.cabecera[ini..ini + n].copy_from_slice(&buf[..n]);
            n
        } else {
            self.disco.seek(SeekFrom::Start(self.posicion))?;
            self.disco.write(buf)?
        };
        self.posicion += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.disco.flush()
    }
}

impl<D: Read + Write + Seek> Seek for CabeceraDiferida<'_, D> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let nueva = match pos {
            SeekFrom::Start(p) => p as i128,
            SeekFrom::Current(d) => self.posicion as i128 + d as i128,
            SeekFrom::End(_) => self.disco.seek(pos)? as i128,
        };
        if nueva < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "posición negativa"));
        }
        self.posicion = nueva as u64;
        Ok(self.posicion)
    }
}

/// Paso del proceso, para mostrar el progreso (en este orden).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Paso {
    Escritura,
    Verificacion,
    Iso,
    Config,
}

/// ISO propia del usuario ("Trae tu ISO"): el archivo y su nombre.
pub struct IsoPropia<'a> {
    pub archivo: &'a mut File,
    pub nombre: &'a str,
}

/// Escribe todo en el disco: imagen, ISO propia (si hay), llevix-config.json y, al
/// final, la tabla de particiones. Luego verifica lo escrito leyendo el disco.
///
/// El disco debe estar ya sin tabla de particiones (el creador la borra antes).
pub fn escribir_todo<R: Read, D: Read + Write + Seek>(
    imagen: R,
    bmap: &Bmap,
    disco: &mut D,
    iso_propia: Option<IsoPropia<'_>>,
    config: &[u8],
    cancelar: &AtomicBool,
    progreso: &mut dyn FnMut(Paso, u64, u64),
) -> Resultado<()> {
    {
        let mut diferido = CabeceraDiferida::new(disco);
        escritura::escribir(imagen, bmap, &mut diferido, cancelar, &mut |p| {
            progreso(Paso::Escritura, p.hechos, p.total)
        })?;
        // Se verifica la imagen antes de agregarle nada (la ISO y el config cambian
        // partes del disco). El primer MiB sale de memoria; se comprueba en `confirmar`.
        escritura::verificar(bmap, &mut diferido, cancelar, &mut |p| {
            progreso(Paso::Verificacion, p.hechos, p.total)
        })?;
        if let Some(iso) = iso_propia {
            iso::escribir_iso(iso.archivo, iso.nombre, &mut diferido, cancelar, &mut |h, t| {
                progreso(Paso::Iso, h, t)
            })?;
        }
        progreso(Paso::Config, 0, 1);
        esp::escribir_config(&mut diferido, config)?;
        diferido.confirmar()?;
    }
    if esp::leer_config(disco)? != config {
        return Err(Error::Verificacion("llevix-config.json no se guardó bien".into()));
    }
    progreso(Paso::Config, 1, 1);
    Ok(())
}

#[cfg(test)]
mod pruebas {
    use super::*;
    use std::io::Cursor;

    /// Disco simulado que anota cada escritura (posición y largo).
    struct DiscoQueAnota {
        datos: Cursor<Vec<u8>>,
        escrituras: Vec<(u64, usize)>,
    }
    impl Read for DiscoQueAnota {
        fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
            self.datos.read(b)
        }
    }
    impl Write for DiscoQueAnota {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            self.escrituras.push((self.datos.position(), b.len()));
            self.datos.write(b)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Seek for DiscoQueAnota {
        fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
            self.datos.seek(p)
        }
    }

    #[test]
    fn la_cabecera_se_escribe_al_final_y_se_lee_de_memoria() {
        let mut disco = DiscoQueAnota { datos: Cursor::new(vec![0xEE; 4 * 1024 * 1024]), escrituras: vec![] };
        {
            let mut d = CabeceraDiferida::new(&mut disco);
            // Una escritura que cruza el límite del primer MiB.
            d.seek(SeekFrom::Start(TAM_CABECERA - 512)).unwrap();
            d.write_all(&[7u8; 1024]).unwrap();
            d.seek(SeekFrom::Start(512)).unwrap();
            d.write_all(b"EFI PART").unwrap();
            // Se lee lo escrito, aunque todavía no esté en el disco.
            let mut b = [0u8; 8];
            d.seek(SeekFrom::Start(512)).unwrap();
            d.read_exact(&mut b).unwrap();
            assert_eq!(&b, b"EFI PART");
            let mut b = [0u8; 1024];
            d.seek(SeekFrom::Start(TAM_CABECERA - 512)).unwrap();
            d.read_exact(&mut b).unwrap();
            assert!(b.iter().all(|&x| x == 7));
            // Hasta aquí, nada se escribió en el primer MiB del disco.
            assert!(d.disco.escrituras.iter().all(|&(p, _)| p >= TAM_CABECERA));
            d.confirmar().unwrap();
        }
        let (p, n) = *disco.escrituras.last().unwrap();
        assert_eq!((p, n), (0, TAM_CABECERA as usize), "la cabecera va en la última escritura");
        let datos = disco.datos.into_inner();
        assert_eq!(&datos[512..520], b"EFI PART");
        assert!(datos[TAM_CABECERA as usize..TAM_CABECERA as usize + 512].iter().all(|&x| x == 7));
        assert_eq!(datos[TAM_CABECERA as usize + 512], 0xEE);
    }
}
