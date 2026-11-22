//! Núcleo del creador de Llevix.
//!
//! Todo lo que no depende de la interfaz gráfica vive aquí, para poder probarlo con
//! `cargo test` sin ventanas y sin discos reales:
//!
//! - [`manifest`]: lee el `manifest.json` de un Release.
//! - [`bmap`]: lee el mapa `.bmap` (qué bloques de la imagen tienen datos).
//! - [`escritura`]: descomprime zstd y escribe solo los bloques con datos, verificando.
//! - [`gpt`] y [`esp`]: buscan la partición EFI y dejan `llevix-config.json` en ella.
//! - [`config`]: arma y valida `llevix-config.json` (la contraseña solo como hash SHA-512).
//! - [`disco`]: decide qué discos se pueden mostrar (solo USB, nunca el del sistema).
//! - [`descarga`]: descarga con reanudación y verificación SHA256.
//! - `windows` (solo en Windows): enumera discos reales y los abre para escribir.

pub mod bmap;
pub mod config;
pub mod descarga;
pub mod disco;
pub mod error;
pub mod escritura;
pub mod esp;
pub mod gpt;
pub mod iso;
pub mod manifest;

#[cfg(windows)]
pub mod windows;

pub use error::{Error, Resultado};
