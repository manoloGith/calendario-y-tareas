//! Errores del núcleo. Se envían a la interfaz como texto legible en español.
use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("Contraseña incorrecta o archivo dañado")]
    WrongPassword,
    #[error("La bóveda está bloqueada")]
    Locked,
    #[error("No encontrado: {0}")]
    NotFound(String),
    #[error("Dato no válido: {0}")]
    Invalid(String),
    #[error("Error de base de datos: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("Error de E/S: {0}")]
    Io(#[from] std::io::Error),
    #[error("Error de formato: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Error de red: {0}")]
    Net(String),
    #[error("Error de CalDAV: {0}")]
    CalDav(String),
    #[error("Error de cifrado: {0}")]
    Crypto(String),
    #[error("Sincronización: {0}")]
    Sync(String),
    #[error("Llavero del sistema: {0}")]
    Keyring(String),
}

pub type Result<T> = std::result::Result<T, Error>;
