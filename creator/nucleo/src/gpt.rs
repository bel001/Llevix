//! Lectura mínima de la tabla de particiones GPT (sectores de 512 bytes).
//!
//! Solo se usa para encontrar la partición EFI en el disco recién escrito.

use crate::error::{Error, Resultado};
use std::io::{Read, Seek, SeekFrom};

pub const SECTOR: u64 = 512;

/// GUID del tipo "EFI System Partition" tal como se guarda en disco (mixed-endian).
pub const TIPO_ESP: [u8; 16] = [
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Particion {
    pub numero: u32,
    pub tipo: [u8; 16],
    pub nombre: String,
    pub primer_sector: u64,
    pub ultimo_sector: u64,
}

impl Particion {
    pub fn desplazamiento(&self) -> u64 {
        self.primer_sector * SECTOR
    }
    pub fn tamano(&self) -> u64 {
        (self.ultimo_sector - self.primer_sector + 1) * SECTOR
    }
}

/// Lee las particiones de la GPT principal (LBA 1).
pub fn leer_particiones<D: Read + Seek>(disco: &mut D) -> Resultado<Vec<Particion>> {
    let mut cabecera = [0u8; 512];
    disco.seek(SeekFrom::Start(SECTOR))?;
    disco.read_exact(&mut cabecera)?;
    if &cabecera[0..8] != b"EFI PART" {
        return Err(Error::Gpt("no hay firma GPT en el sector 1".into()));
    }
    let u32_en = |o: usize| u32::from_le_bytes(cabecera[o..o + 4].try_into().unwrap());
    let u64_en = |o: usize| u64::from_le_bytes(cabecera[o..o + 8].try_into().unwrap());

    let lba_entradas = u64_en(72);
    let cantidad = u32_en(80);
    let tamano_entrada = u32_en(84) as usize;
    if !(128..=4096).contains(&tamano_entrada) || cantidad == 0 || cantidad > 1024 {
        return Err(Error::Gpt("cabecera GPT con valores fuera de rango".into()));
    }

    let mut entradas = vec![0u8; cantidad as usize * tamano_entrada];
    let largo_alineado = entradas.len().div_ceil(512) * 512;
    entradas.resize(largo_alineado, 0);
    disco.seek(SeekFrom::Start(lba_entradas * SECTOR))?;
    disco.read_exact(&mut entradas)?;

    let mut particiones = Vec::new();
    for i in 0..cantidad as usize {
        let e = &entradas[i * tamano_entrada..(i + 1) * tamano_entrada];
        let tipo: [u8; 16] = e[0..16].try_into().unwrap();
        if tipo == [0u8; 16] {
            continue;
        }
        let primer_sector = u64::from_le_bytes(e[32..40].try_into().unwrap());
        let ultimo_sector = u64::from_le_bytes(e[40..48].try_into().unwrap());
        if ultimo_sector < primer_sector {
            return Err(Error::Gpt(format!("partición {} con límites inválidos", i + 1)));
        }
        let utf16: Vec<u16> = e[56..128]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .take_while(|&c| c != 0)
            .collect();
        particiones.push(Particion {
            numero: i as u32 + 1,
            tipo,
            nombre: String::from_utf16_lossy(&utf16),
            primer_sector,
            ultimo_sector,
        });
    }
    Ok(particiones)
}

/// Devuelve la partición EFI (la primera con el tipo ESP).
pub fn buscar_esp<D: Read + Seek>(disco: &mut D) -> Resultado<Particion> {
    leer_particiones(disco)?
        .into_iter()
        .find(|p| p.tipo == TIPO_ESP)
        .ok_or_else(|| Error::Gpt("no se encontró la partición EFI".into()))
}

#[cfg(test)]
pub(crate) mod pruebas {
    use super::*;
    use std::io::Cursor;

    /// Escribe una GPT mínima con las particiones dadas: (tipo, nombre, primer, último).
    pub fn escribir_gpt(disco: &mut [u8], particiones: &[([u8; 16], &str, u64, u64)]) {
        let cab = &mut disco[512..1024];
        cab[0..8].copy_from_slice(b"EFI PART");
        cab[72..80].copy_from_slice(&2u64.to_le_bytes()); // entradas en LBA 2
        cab[80..84].copy_from_slice(&128u32.to_le_bytes());
        cab[84..88].copy_from_slice(&128u32.to_le_bytes());
        for (i, (tipo, nombre, a, b)) in particiones.iter().enumerate() {
            let o = 1024 + i * 128;
            let e = &mut disco[o..o + 128];
            e[0..16].copy_from_slice(tipo);
            e[16] = 1; // GUID único cualquiera distinto de cero
            e[32..40].copy_from_slice(&a.to_le_bytes());
            e[40..48].copy_from_slice(&b.to_le_bytes());
            for (j, c) in nombre.encode_utf16().enumerate() {
                e[56 + j * 2..58 + j * 2].copy_from_slice(&c.to_le_bytes());
            }
        }
    }

    #[test]
    fn encuentra_la_particion_efi() {
        let mut disco = vec![0u8; 1024 * 1024];
        let datos = [0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7];
        escribir_gpt(&mut disco, &[(datos, "LLEVIX-DATOS", 1500, 2000), (TIPO_ESP, "LLEVIX-EFI", 100, 1499)]);
        let esp = buscar_esp(&mut Cursor::new(disco)).unwrap();
        assert_eq!(esp.numero, 2);
        assert_eq!(esp.nombre, "LLEVIX-EFI");
        assert_eq!(esp.desplazamiento(), 100 * 512);
        assert_eq!(esp.tamano(), 1400 * 512);
    }

    #[test]
    fn falla_sin_gpt() {
        assert!(leer_particiones(&mut Cursor::new(vec![0u8; 8192])).is_err());
    }
}
