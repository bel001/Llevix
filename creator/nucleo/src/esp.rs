//! Escribe `llevix-config.json` en la partición EFI (FAT32) del disco recién escrito,
//! sin que Windows tenga que montarla.
//!
//! Los discos físicos solo aceptan lecturas y escrituras de sectores completos en
//! posiciones alineadas. [`VistaParticion`] traduce las operaciones pequeñas de la
//! biblioteca FAT a sectores completos (leer, modificar y volver a escribir).

use crate::error::{Error, Resultado};
use crate::gpt;
use std::io::{self, Read, Seek, SeekFrom, Write};

pub const NOMBRE_CONFIG: &str = "llevix-config.json";

/// Una partición dentro de un disco, vista como si fuera un archivo, con acceso por
/// sectores completos de 512 bytes.
pub struct VistaParticion<'a, D> {
    disco: &'a mut D,
    inicio: u64,
    tamano: u64,
    posicion: u64,
}

impl<'a, D: Read + Write + Seek> VistaParticion<'a, D> {
    pub fn new(disco: &'a mut D, inicio: u64, tamano: u64) -> Self {
        assert_eq!(inicio % gpt::SECTOR, 0);
        VistaParticion { disco, inicio, tamano, posicion: 0 }
    }

    fn leer_sector(&mut self, sector: u64, buf: &mut [u8; 512]) -> io::Result<()> {
        self.disco.seek(SeekFrom::Start(self.inicio + sector * 512))?;
        self.disco.read_exact(buf)
    }

    fn escribir_sector(&mut self, sector: u64, buf: &[u8; 512]) -> io::Result<()> {
        self.disco.seek(SeekFrom::Start(self.inicio + sector * 512))?;
        self.disco.write_all(buf)
    }
}

impl<D: Read + Write + Seek> Read for VistaParticion<'_, D> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.posicion >= self.tamano || buf.is_empty() {
            return Ok(0);
        }
        let sector = self.posicion / 512;
        let dentro = (self.posicion % 512) as usize;
        let n = buf.len().min(512 - dentro).min((self.tamano - self.posicion) as usize);
        let mut s = [0u8; 512];
        self.leer_sector(sector, &mut s)?;
        buf[..n].copy_from_slice(&s[dentro..dentro + n]);
        self.posicion += n as u64;
        Ok(n)
    }
}

impl<D: Read + Write + Seek> Write for VistaParticion<'_, D> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.posicion >= self.tamano {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "fin de la partición"));
        }
        if buf.is_empty() {
            return Ok(0);
        }
        let sector = self.posicion / 512;
        let dentro = (self.posicion % 512) as usize;
        let n = buf.len().min(512 - dentro).min((self.tamano - self.posicion) as usize);
        let mut s = [0u8; 512];
        if n < 512 {
            self.leer_sector(sector, &mut s)?;
        }
        s[dentro..dentro + n].copy_from_slice(&buf[..n]);
        self.escribir_sector(sector, &s)?;
        self.posicion += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.disco.flush()
    }
}

impl<D: Read + Write + Seek> Seek for VistaParticion<'_, D> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let nueva = match pos {
            SeekFrom::Start(p) => p as i128,
            SeekFrom::Current(d) => self.posicion as i128 + d as i128,
            SeekFrom::End(d) => self.tamano as i128 + d as i128,
        };
        if nueva < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "posición negativa"));
        }
        self.posicion = nueva as u64;
        Ok(self.posicion)
    }
}

/// Busca la partición EFI del disco y guarda `contenido` como `llevix-config.json`.
pub fn escribir_config<D: Read + Write + Seek>(disco: &mut D, contenido: &[u8]) -> Resultado<()> {
    let esp = gpt::buscar_esp(disco)?;
    let vista = VistaParticion::new(disco, esp.desplazamiento(), esp.tamano());
    let fs = fatfs::FileSystem::new(vista, fatfs::FsOptions::new())
        .map_err(|e| Error::Esp(format!("no se pudo abrir el sistema de archivos FAT: {e}")))?;
    {
        let raiz = fs.root_dir();
        let mut archivo = raiz
            .create_file(NOMBRE_CONFIG)
            .map_err(|e| Error::Esp(format!("no se pudo crear {NOMBRE_CONFIG}: {e}")))?;
        archivo.truncate().map_err(|e| Error::Esp(e.to_string()))?;
        archivo.write_all(contenido).map_err(|e| Error::Esp(e.to_string()))?;
        archivo.flush().map_err(|e| Error::Esp(e.to_string()))?;
    }
    fs.unmount().map_err(|e| Error::Esp(e.to_string()))?;
    disco.flush()?;
    Ok(())
}

/// Lee `llevix-config.json` de la partición EFI (para comprobar lo escrito).
pub fn leer_config<D: Read + Write + Seek>(disco: &mut D) -> Resultado<Vec<u8>> {
    let esp = gpt::buscar_esp(disco)?;
    let vista = VistaParticion::new(disco, esp.desplazamiento(), esp.tamano());
    let fs = fatfs::FileSystem::new(vista, fatfs::FsOptions::new())
        .map_err(|e| Error::Esp(format!("no se pudo abrir el sistema de archivos FAT: {e}")))?;
    let mut contenido = Vec::new();
    fs.root_dir()
        .open_file(NOMBRE_CONFIG)
        .map_err(|e| Error::Esp(e.to_string()))?
        .read_to_end(&mut contenido)?;
    Ok(contenido)
}

#[cfg(test)]
mod pruebas {
    use super::*;
    use crate::gpt::pruebas::escribir_gpt;
    use crate::gpt::TIPO_ESP;
    use std::io::Cursor;

    /// Disco simulado de 48 MiB con GPT y una ESP FAT32 de 40 MiB que ya tiene un archivo.
    fn disco_con_esp() -> Cursor<Vec<u8>> {
        let mut disco = vec![0u8; 48 * 1024 * 1024];
        let primer = 2048u64;
        let ultimo = primer + 40 * 1024 * 2 - 1;
        escribir_gpt(&mut disco, &[(TIPO_ESP, "LLEVIX-EFI", primer, ultimo)]);
        let mut cursor = Cursor::new(disco);
        {
            let mut vista = VistaParticion::new(&mut cursor, primer * 512, (ultimo - primer + 1) * 512);
            fatfs::format_volume(
                &mut vista,
                fatfs::FormatVolumeOptions::new().fat_type(fatfs::FatType::Fat32).volume_label(*b"LLEVIX-EFI "),
            )
            .unwrap();
            let fs = fatfs::FileSystem::new(&mut vista, fatfs::FsOptions::new()).unwrap();
            fs.root_dir().create_dir("EFI").unwrap();
            fs.root_dir().create_file("existente.txt").unwrap().write_all(b"hola").unwrap();
            fs.unmount().unwrap();
        }
        cursor
    }

    /// Flujo completo del creador con un disco simulado (archivo): imagen con GPT y ESP →
    /// zstd + bmap → escritura y verificación → llevix-config.json en la ESP.
    #[test]
    fn flujo_completo_con_disco_simulado() {
        use crate::bmap::{pruebas::crear_bmap, Bmap};
        use crate::crear::escribir_todo;
        use std::sync::atomic::AtomicBool;

        let imagen = disco_con_esp().into_inner();
        let bmap = Bmap::leer(&crear_bmap(&imagen, 4096)).unwrap();
        let zst = zstd::stream::encode_all(Cursor::new(&imagen), 3).unwrap();

        // "Disco USB" de 64 MiB con basura previa.
        let archivo = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(archivo.path(), vec![0x5Au8; 64 * 1024 * 1024]).unwrap();
        let mut disco = std::fs::OpenOptions::new().read(true).write(true).open(archivo.path()).unwrap();

        let config = br#"{"version":1,"usuario":{"nombre":"ana"}}"#;
        escribir_todo(Cursor::new(zst), &bmap, &mut disco, None, config, &AtomicBool::new(false), &mut |_, _, _| {})
            .unwrap();
        assert_eq!(leer_config(&mut disco).unwrap(), config);
        // Lo que no era de la imagen (después de su final) no se tocó.
        let todo = std::fs::read(archivo.path()).unwrap();
        assert!(todo[imagen.len()..].iter().all(|&b| b == 0x5A));
    }

    #[test]
    fn escribe_y_lee_el_config_en_la_esp() {
        let mut disco = disco_con_esp();
        let contenido = br#"{"version":1}"#;
        escribir_config(&mut disco, contenido).unwrap();
        assert_eq!(leer_config(&mut disco).unwrap(), contenido);

        // Escribirlo otra vez lo reemplaza (no lo duplica ni deja restos).
        escribir_config(&mut disco, b"{}").unwrap();
        assert_eq!(leer_config(&mut disco).unwrap(), b"{}");

        // Lo que ya había en la ESP sigue ahí.
        let esp = gpt::buscar_esp(&mut disco).unwrap();
        let vista = VistaParticion::new(&mut disco, esp.desplazamiento(), esp.tamano());
        let fs = fatfs::FileSystem::new(vista, fatfs::FsOptions::new()).unwrap();
        let mut texto = String::new();
        fs.root_dir().open_file("existente.txt").unwrap().read_to_string(&mut texto).unwrap();
        assert_eq!(texto, "hola");
    }
}
