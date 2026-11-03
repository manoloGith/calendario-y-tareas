//! Cifrado autenticado (XChaCha20-Poly1305 + Argon2id) y copias de seguridad `.calbak`.
//! El mismo sobre cifrado servirá para los blobs del futuro servidor zero-knowledge.
use crate::db::Db;
use crate::error::{Error, Result};
use crate::model::*;
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::Path;

const MAGIC: &[u8; 8] = b"CALBAK01";
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;

pub fn derive_key(password: &str, salt: &[u8]) -> Result<[u8; 32]> {
    let params = Params::new(64 * 1024, 3, 1, Some(32)).map_err(|e| Error::Crypto(e.to_string()))?;
    let mut key = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|e| Error::Crypto(e.to_string()))?;
    Ok(key)
}

/// Cifra con clave de 32 bytes. Formato: nonce(24) || texto cifrado + etiqueta.
pub fn seal(key: &[u8; 32], plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce = [0u8; NONCE_LEN];
    rand::thread_rng().fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(XNonce::from_slice(&nonce), chacha20poly1305::aead::Payload { msg: plaintext, aad })
        .map_err(|_| Error::Crypto("no se pudo cifrar".into()))?;
    let mut out = nonce.to_vec();
    out.extend(ct);
    Ok(out)
}

pub fn open(key: &[u8; 32], sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < NONCE_LEN + 16 {
        return Err(Error::Crypto("datos cifrados truncados".into()));
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(
            XNonce::from_slice(&sealed[..NONCE_LEN]),
            chacha20poly1305::aead::Payload { msg: &sealed[NONCE_LEN..], aad },
        )
        .map_err(|_| Error::Crypto("contraseña incorrecta o copia dañada".into()))
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    format: u32,
    created: String,
    app_version: String,
    accounts: Vec<AccountFull>,
    calendars: Vec<Calendar>,
    events: Vec<Event>,
    tasks: Vec<Task>,
    #[serde(default)]
    attachments: Vec<AttachmentFull>,
}

/// Adjunto con su contenido en base64 (va dentro de la copia cifrada).
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AttachmentFull {
    #[serde(flatten)]
    meta: Attachment,
    #[serde(default)]
    data: Option<String>,
}

/// Las contraseñas CalDAV también viajan en la copia (va cifrada).
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AccountFull {
    #[serde(flatten)]
    account: Account,
    password: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct BackupInfo {
    pub path: String,
    pub bytes: u64,
    pub calendars: usize,
    pub events: usize,
    pub tasks: usize,
    pub created: String,
}

pub fn create(db: &Db, path: &Path, password: &str) -> Result<BackupInfo> {
    if password.chars().count() < 8 {
        return Err(Error::Invalid("la contraseña de la copia debe tener al menos 8 caracteres".into()));
    }
    let snap = Snapshot {
        format: 1,
        created: crate::time::now_utc_string(),
        app_version: env!("CARGO_PKG_VERSION").into(),
        accounts: db
            .accounts()?
            .into_iter()
            .map(|a| AccountFull { password: a.password.clone(), account: a })
            .collect(),
        calendars: db.calendars()?,
        events: db.all_events()?,
        tasks: db.all_tasks()?,
        attachments: db
            .all_attachments()?
            .into_iter()
            .map(|(meta, data)| AttachmentFull { meta, data: data.map(|d| B64.encode(d)) })
            .collect(),
    };
    let json = serde_json::to_vec(&snap)?;
    let mut gz = GzEncoder::new(Vec::new(), flate2::Compression::default());
    gz.write_all(&json)?;
    let compressed = gz.finish()?;
    let mut salt = [0u8; SALT_LEN];
    rand::thread_rng().fill_bytes(&mut salt);
    let key = derive_key(password, &salt)?;
    let sealed = seal(&key, &compressed, MAGIC)?;
    let mut file = Vec::with_capacity(8 + SALT_LEN + sealed.len());
    file.extend_from_slice(MAGIC);
    file.extend_from_slice(&salt);
    file.extend(sealed);
    // Escritura atómica: archivo temporal y renombrado.
    let tmp = path.with_extension("calbak.tmp");
    std::fs::write(&tmp, &file)?;
    std::fs::rename(&tmp, path)?;
    // Verificación: se vuelve a leer y descifrar.
    let check = read_snapshot(path, password)?;
    Ok(BackupInfo {
        path: path.display().to_string(),
        bytes: file.len() as u64,
        calendars: check.calendars.len(),
        events: check.events.len(),
        tasks: check.tasks.len(),
        created: check.created,
    })
}

fn read_snapshot(path: &Path, password: &str) -> Result<Snapshot> {
    let data = std::fs::read(path)?;
    if data.len() < 8 + SALT_LEN || &data[..8] != MAGIC {
        return Err(Error::Invalid("no es una copia de seguridad de Calendario y Tareas".into()));
    }
    let key = derive_key(password, &data[8..8 + SALT_LEN])?;
    let compressed = open(&key, &data[8 + SALT_LEN..], MAGIC)?;
    let mut json = Vec::new();
    GzDecoder::new(&compressed[..]).read_to_end(&mut json)?;
    Ok(serde_json::from_slice(&json)?)
}

pub fn inspect(path: &Path, password: &str) -> Result<BackupInfo> {
    let s = read_snapshot(path, password)?;
    Ok(BackupInfo {
        path: path.display().to_string(),
        bytes: std::fs::metadata(path)?.len(),
        calendars: s.calendars.len(),
        events: s.events.len(),
        tasks: s.tasks.len(),
        created: s.created,
    })
}

/// Restaura una copia. `replace = true` borra antes todos los datos; si no, fusiona (la copia gana).
pub fn restore(db: &mut Db, path: &Path, password: &str, replace: bool) -> Result<BackupInfo> {
    let snap = read_snapshot(path, password)?;
    let info = BackupInfo {
        path: path.display().to_string(),
        bytes: std::fs::metadata(path)?.len(),
        calendars: snap.calendars.len(),
        events: snap.events.len(),
        tasks: snap.tasks.len(),
        created: snap.created.clone(),
    };
    db.transaction(|db| {
        if replace {
            db.conn.execute_batch("DELETE FROM attachments; DELETE FROM events; DELETE FROM tasks; DELETE FROM calendars; DELETE FROM accounts;")?;
        }
        for a in snap.accounts {
            let mut acc = a.account;
            acc.password = a.password;
            db.save_account(&acc)?;
        }
        for mut c in snap.calendars {
            db.save_calendar(&mut c)?;
        }
        for mut e in snap.events {
            db.save_event(&mut e, false)?;
        }
        // Primero las tareas madre para respetar el orden.
        let (roots, subs): (Vec<Task>, Vec<Task>) = snap.tasks.into_iter().partition(|t| t.parent_id.is_none());
        for mut t in roots.into_iter().chain(subs) {
            db.save_task(&mut t, false)?;
        }
        for at in snap.attachments {
            let data = match at.data {
                Some(d) => Some(B64.decode(d).map_err(|e| Error::Invalid(format!("adjunto dañado: {e}")))?),
                None => None,
            };
            db.save_attachment(&at.meta, data.as_deref())?;
        }
        Ok(())
    })?;
    Ok(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open() {
        let key = derive_key("contraseña segura", b"0123456789abcdef").unwrap();
        let s = seal(&key, b"hola", b"aad").unwrap();
        assert_eq!(open(&key, &s, b"aad").unwrap(), b"hola");
        assert!(open(&key, &s, b"otra").is_err());
        let bad = derive_key("otra", b"0123456789abcdef").unwrap();
        assert!(open(&bad, &s, b"aad").is_err());
    }
}
