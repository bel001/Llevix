//! Errores del creador, con mensajes en español pensados para mostrarse al usuario.

use thiserror::Error;

pub type Resultado<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("Error de lectura o escritura: {0}")]
    Io(#[from] std::io::Error),

    #[error("El mapa de bloques (.bmap) no es válido: {0}")]
    Bmap(String),

    #[error("La imagen descargada está dañada: {0}")]
    Integridad(String),

    #[error("La verificación de lo escrito falló: {0}")]
    Verificacion(String),

    #[error("La tabla de particiones no es válida: {0}")]
    Gpt(String),

    #[error("No se pudo escribir la configuración en la partición EFI: {0}")]
    Esp(String),

    #[error("Configuración no válida: {0}")]
    Config(String),

    #[error("No se pudo descargar: {0}")]
    Descarga(String),

    #[error("La lista de versiones (manifest.json) no es válida: {0}")]
    Manifest(String),

    #[error("Disco no permitido: {0}")]
    DiscoNoPermitido(String),

    /// El mensaje ya viene completo (ver prueba_disco).
    #[error("{0}")]
    DiscoDefectuoso(String),

    #[error("Operación cancelada")]
    Cancelado,
}
