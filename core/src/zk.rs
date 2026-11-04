//! Cliente del servidor de sincronización zero-knowledge.
//!
//! Claves:
//!  - De la contraseña y la sal de la cuenta se derivan con Argon2id 64 bytes: los primeros 32 son la clave
//!    que envuelve la clave de cuenta (nunca sale del equipo) y los últimos 32, la clave de acceso que se
//!    envía al servidor (que solo guarda un resumen).
//!  - La clave de cuenta (32 bytes aleatorios) cifra todos los datos. En el servidor solo está envuelta:
//!    con la contraseña y con el código de recuperación.
//!  - Cada calendario, evento, tarea o adjunto es un bloque: id = HMAC(clave de cuenta, «tipo:id»), contenido
//!    = XChaCha20-Poly1305(clave de cuenta, gzip(JSON)), con el id como datos asociados.
//!
//! Se sincronizan los calendarios y listas «En este equipo» (los de CalDAV y .ics ya tienen su propio origen).
use crate::backup::{derive_bytes, open as unseal, seal};
use crate::db::Db;
use crate::endpoints::{self, Probe};
use crate::error::{Error, Result};
use crate::model::*;
use crate::time;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use hmac::{Hmac, Mac};
use rand::RngCore;
use reqwest::blocking::Client;
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

const WRAP_AAD: &[u8] = b"calzk-wrap-v1";
/// Tamaño máximo (aprox.) de cada envío al servidor.
const PUSH_BYTES: usize = 40 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZkAccount {
    pub id: String,
    pub name: String,
    pub urls: Vec<String>,
    pub active_url: Option<String>,
    pub username: String,
    pub last_seq: i64,
    pub last_sync: Option<String>,
    pub last_error: Option<String>,
    #[serde(skip)]
    pub token: String,
    #[serde(skip)]
    pub key: Vec<u8>,
    #[serde(skip)]
    pub pushed_seq: i64,
}

#[derive(Debug, Default, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ZkStats {
    pub uploaded: usize,
    pub downloaded: usize,
    pub deleted: usize,
    pub conflicts: usize,
}

// ------------------------------------------------------------------ almacenamiento local

pub fn accounts(db: &Db) -> Result<Vec<ZkAccount>> {
    let mut st = db.conn.prepare(
        "SELECT id, name, urls, active_url, username, token, account_key, last_seq, pushed_seq, last_sync, last_error FROM zk_accounts ORDER BY name",
    )?;
    let rows = st.query_map([], |r| {
        let urls: String = r.get(2)?;
        Ok(ZkAccount {
            id: r.get(0)?,
            name: r.get(1)?,
            urls: serde_json::from_str(&urls).unwrap_or_default(),
            active_url: r.get(3)?,
            username: r.get(4)?,
            token: r.get(5)?,
            key: r.get(6)?,
            last_seq: r.get(7)?,
            pushed_seq: r.get(8)?,
            last_sync: r.get(9)?,
            last_error: r.get(10)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

pub fn account(db: &Db, id: &str) -> Result<ZkAccount> {
    accounts(db)?.into_iter().find(|a| a.id == id).ok_or_else(|| Error::NotFound(format!("cuenta {id}")))
}

pub fn save_account(db: &Db, a: &ZkAccount) -> Result<()> {
    db.conn.execute(
        "INSERT INTO zk_accounts(id, name, urls, active_url, username, token, account_key, last_seq, pushed_seq, last_sync, last_error)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT(id) DO UPDATE SET name=?2, urls=?3, active_url=?4, username=?5, token=?6, account_key=?7,
           last_seq=?8, pushed_seq=?9, last_sync=?10, last_error=?11",
        params![
            a.id, a.name, serde_json::to_string(&a.urls)?, a.active_url, a.username, a.token, a.key,
            a.last_seq, a.pushed_seq, a.last_sync, a.last_error
        ],
    )?;
    Ok(())
}

pub fn remove_account(db: &Db, id: &str) -> Result<()> {
    db.conn.execute("DELETE FROM zk_accounts WHERE id=?1", params![id])?;
    Ok(())
}

// ------------------------------------------------------------------ claves

fn derive(secret: &str, salt: &[u8]) -> Result<([u8; 32], [u8; 32])> {
    let out = derive_bytes(secret, salt, 64)?;
    let mut kek = [0u8; 32];
    let mut auth = [0u8; 32];
    kek.copy_from_slice(&out[..32]);
    auth.copy_from_slice(&out[32..]);
    Ok((kek, auth))
}

fn key32(v: &[u8]) -> Result<[u8; 32]> {
    v.try_into().map_err(|_| Error::Crypto("clave de cuenta con longitud incorrecta".into()))
}

/// Código de recuperación: 25 caracteres en grupos de 5 (sin letras confusas).
fn new_recovery_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut raw = [0u8; 25];
    rand::thread_rng().fill_bytes(&mut raw);
    let chars: Vec<char> = raw.iter().map(|b| ALPHABET[(*b as usize) % ALPHABET.len()] as char).collect();
    chars.chunks(5).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("-")
}

fn normalize_code(code: &str) -> String {
    code.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_uppercase()).collect()
}

fn blob_id(key: &[u8], kind: &str, id: &str) -> String {
    let mut m = Hmac::<Sha256>::new_from_slice(key).expect("hmac");
    m.update(kind.as_bytes());
    m.update(b":");
    m.update(id.as_bytes());
    m.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

fn encrypt(key: &[u8; 32], bid: &str, payload: &Value) -> Result<String> {
    let mut gz = GzEncoder::new(Vec::new(), flate2::Compression::default());
    gz.write_all(&serde_json::to_vec(payload)?)?;
    Ok(B64.encode(seal(key, &gz.finish()?, bid.as_bytes())?))
}

fn decrypt(key: &[u8; 32], bid: &str, data: &str) -> Result<Value> {
    let raw = B64.decode(data).map_err(|e| Error::Sync(format!("bloque dañado: {e}")))?;
    let plain = unseal(key, &raw, bid.as_bytes())?;
    let mut json = Vec::new();
    GzDecoder::new(&plain[..]).read_to_end(&mut json)?;
    Ok(serde_json::from_slice(&json)?)
}

// ------------------------------------------------------------------ HTTP

struct Http {
    client: Client,
    base: String,
    token: Option<String>,
}

impl Http {
    fn new(base: &str, token: Option<&str>, timeout: Duration) -> Result<Http> {
        let client = Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout.min(Duration::from_secs(5)))
            .user_agent(concat!("CalendarioYTareas/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| Error::Net(e.to_string()))?;
        Ok(Http { client, base: base.trim_end_matches('/').to_string(), token: token.map(|s| s.to_string()) })
    }

    fn send(&self, rq: reqwest::blocking::RequestBuilder) -> Result<Value> {
        let rq = match &self.token {
            Some(t) => rq.bearer_auth(t),
            None => rq,
        };
        let r = rq.send().map_err(|e| Error::Net(e.to_string()))?;
        let status = r.status();
        let body: Value = r.text().ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
        if status.is_success() {
            return Ok(body);
        }
        let msg = body.get("error").and_then(|e| e.as_str()).unwrap_or("error del servidor").to_string();
        Err(match status.as_u16() {
            401 if self.token.is_some() => Error::Sync("la sesión ha caducado: vuelve a conectar la cuenta".into()),
            _ => Error::Sync(msg),
        })
    }

    fn get(&self, path: &str) -> Result<Value> {
        self.send(self.client.get(format!("{}{path}", self.base)))
    }

    fn post(&self, path: &str, body: &Value) -> Result<Value> {
        self.send(
            self.client
                .post(format!("{}{path}", self.base))
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(serde_json::to_vec(body).unwrap_or_default()),
        )
    }
}

/// Comprueba que la dirección es un servidor de Calendario y Tareas.
fn check(url: &str) -> Result<()> {
    let h = Http::new(url, None, endpoints::PROBE_TIMEOUT)?;
    let v = h.get("/v1/health")?;
    if v.get("service").and_then(|s| s.as_str()) == Some("calendario-zk") {
        Ok(())
    } else {
        Err(Error::Sync("no es un servidor de Calendario y Tareas".into()))
    }
}

pub fn test(urls: &[String]) -> Result<Vec<Probe>> {
    let urls = endpoints::normalize(urls)?;
    Ok(urls.iter().map(|u| endpoints::probe(u, check)).collect())
}

fn device_name() -> String {
    let host = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "equipo".into());
    format!("{host} ({})", std::env::consts::OS)
}

// ------------------------------------------------------------------ alta, acceso, recuperación

pub struct Linked {
    pub account: ZkAccount,
    pub recovery_code: Option<String>,
}

/// Crea una cuenta en el servidor. Devuelve el código de recuperación (se muestra una sola vez).
pub fn register(db: &Db, name: &str, urls: &[String], username: &str, password: &str) -> Result<Linked> {
    if password.chars().count() < 10 {
        return Err(Error::Invalid("la contraseña de sincronización debe tener al menos 10 caracteres".into()));
    }
    let urls = endpoints::normalize(urls)?;
    let active = endpoints::pick(&urls, None, check)?;
    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);
    let mut account_key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut account_key);
    let (kek, auth) = derive(password, &salt)?;
    let code = new_recovery_code();
    let (rkek, rauth) = derive(&normalize_code(&code), &salt)?;
    let h = Http::new(&active, None, Duration::from_secs(30))?;
    let r = h.post(
        "/v1/register",
        &json!({
            "username": username.trim(),
            "salt": B64.encode(salt),
            "authKey": B64.encode(auth),
            "wrappedKey": B64.encode(seal(&kek, &account_key, WRAP_AAD)?),
            "recoveryAuthKey": B64.encode(rauth),
            "recoveryWrappedKey": B64.encode(seal(&rkek, &account_key, WRAP_AAD)?),
            "device": device_name(),
        }),
    )?;
    let acc = new_account(name, &urls, &active, username, r, &account_key)?;
    save_account(db, &acc)?;
    Ok(Linked { account: acc, recovery_code: Some(code) })
}

fn new_account(name: &str, urls: &[String], active: &str, username: &str, r: Value, key: &[u8]) -> Result<ZkAccount> {
    Ok(ZkAccount {
        id: uuid::Uuid::new_v4().to_string(),
        name: if name.trim().is_empty() { endpoints::host(&urls[0]) } else { name.trim().to_string() },
        urls: urls.to_vec(),
        active_url: Some(active.to_string()),
        username: username.trim().to_string(),
        last_seq: 0,
        pushed_seq: 0,
        last_sync: None,
        last_error: None,
        token: r.get("token").and_then(|t| t.as_str()).ok_or_else(|| Error::Sync("respuesta sin sesión".into()))?.to_string(),
        key: key.to_vec(),
    })
}

fn salt_for(h: &Http, username: &str) -> Result<Vec<u8>> {
    let r = h.post("/v1/prelogin", &json!({"username": username.trim()}))?;
    B64.decode(r.get("salt").and_then(|s| s.as_str()).unwrap_or("")).map_err(|e| Error::Sync(e.to_string()))
}

/// Conecta este equipo a una cuenta que ya existe.
pub fn login(db: &Db, name: &str, urls: &[String], username: &str, password: &str) -> Result<Linked> {
    let urls = endpoints::normalize(urls)?;
    let active = endpoints::pick(&urls, None, check)?;
    let h = Http::new(&active, None, Duration::from_secs(30))?;
    let salt = salt_for(&h, username)?;
    let (kek, auth) = derive(password, &salt)?;
    let r = h.post("/v1/login", &json!({"username": username.trim(), "authKey": B64.encode(auth), "device": device_name()}))?;
    let wrapped = B64.decode(r.get("wrappedKey").and_then(|s| s.as_str()).unwrap_or("")).map_err(|e| Error::Sync(e.to_string()))?;
    let key = unseal(&kek, &wrapped, WRAP_AAD).map_err(|_| Error::Sync("no se pudo abrir la clave de la cuenta".into()))?;
    let acc = new_account(name, &urls, &active, username, r, &key)?;
    save_account(db, &acc)?;
    Ok(Linked { account: acc, recovery_code: None })
}

/// Con el código de recuperación se fija una contraseña nueva y se conecta este equipo.
pub fn recover(db: &Db, name: &str, urls: &[String], username: &str, code: &str, new_password: &str) -> Result<Linked> {
    if new_password.chars().count() < 10 {
        return Err(Error::Invalid("la contraseña de sincronización debe tener al menos 10 caracteres".into()));
    }
    let urls = endpoints::normalize(urls)?;
    let active = endpoints::pick(&urls, None, check)?;
    let h = Http::new(&active, None, Duration::from_secs(30))?;
    let salt = salt_for(&h, username)?;
    let (rkek, rauth) = derive(&normalize_code(code), &salt)?;
    let r = h.post("/v1/recover", &json!({"username": username.trim(), "recoveryAuthKey": B64.encode(rauth), "device": device_name()}))?;
    let wrapped = B64.decode(r.get("recoveryWrappedKey").and_then(|s| s.as_str()).unwrap_or("")).map_err(|e| Error::Sync(e.to_string()))?;
    let key = unseal(&rkek, &wrapped, WRAP_AAD).map_err(|_| Error::Sync("código de recuperación incorrecto".into()))?;
    let acc = new_account(name, &urls, &active, username, r, &key)?;
    let (kek, auth) = derive(new_password, &salt)?;
    let authed = Http::new(&active, Some(&acc.token), Duration::from_secs(30))?;
    authed.post("/v1/password", &json!({"authKey": B64.encode(auth), "wrappedKey": B64.encode(seal(&kek, &key32(&key)?, WRAP_AAD)?)}))?;
    save_account(db, &acc)?;
    Ok(Linked { account: acc, recovery_code: None })
}

/// Cambia la contraseña de sincronización (los datos no se vuelven a cifrar). Cierra las demás sesiones.
pub fn change_password(db: &Db, id: &str, new_password: &str) -> Result<()> {
    if new_password.chars().count() < 10 {
        return Err(Error::Invalid("la contraseña de sincronización debe tener al menos 10 caracteres".into()));
    }
    let acc = account(db, id)?;
    let active = endpoints::pick(&acc.urls, acc.active_url.as_deref(), check)?;
    let h = Http::new(&active, None, Duration::from_secs(30))?;
    let salt = salt_for(&h, &acc.username)?;
    let (kek, auth) = derive(new_password, &salt)?;
    let authed = Http::new(&active, Some(&acc.token), Duration::from_secs(30))?;
    authed.post("/v1/password", &json!({"authKey": B64.encode(auth), "wrappedKey": B64.encode(seal(&kek, &key32(&acc.key)?, WRAP_AAD)?)}))?;
    Ok(())
}

pub fn update_urls(db: &Db, id: &str, name: Option<&str>, urls: Option<&[String]>) -> Result<ZkAccount> {
    let mut acc = account(db, id)?;
    if let Some(n) = name.map(str::trim).filter(|n| !n.is_empty()) {
        acc.name = n.to_string();
    }
    if let Some(u) = urls {
        acc.urls = endpoints::normalize(u)?;
        if !acc.urls.iter().any(|u| Some(u) == acc.active_url.as_ref()) {
            acc.active_url = None;
        }
    }
    save_account(db, &acc)?;
    Ok(acc)
}

/// Quita la cuenta de este equipo (y opcionalmente borra todos los datos del servidor).
pub fn unlink(db: &Db, id: &str, delete_remote: bool) -> Result<()> {
    let acc = account(db, id)?;
    if let Ok(active) = endpoints::pick(&acc.urls, acc.active_url.as_deref(), check) {
        if let Ok(h) = Http::new(&active, Some(&acc.token), Duration::from_secs(30)) {
            let r = if delete_remote {
                h.send(h.client.delete(format!("{}/v1/account", h.base)))
            } else {
                h.post("/v1/logout", &json!({}))
            };
            if delete_remote {
                r?;
            }
        }
    } else if delete_remote {
        return Err(Error::Net("no se puede contactar con el servidor para borrar la cuenta".into()));
    }
    remove_account(db, id)
}

// ------------------------------------------------------------------ sincronización

fn is_local_calendar(db: &Db, cal_id: &str) -> bool {
    db.calendar(cal_id).map(|c| c.source == SOURCE_LOCAL).unwrap_or(false)
}

/// Contenido de un elemento local para subirlo, o None si no se sincroniza (no es de un calendario local).
fn payload(db: &Db, kind: &str, id: &str) -> Result<Option<Value>> {
    Ok(match kind {
        "calendar" => match db.calendar(id) {
            Ok(c) if c.source == SOURCE_LOCAL => Some(json!({"kind": kind, "id": id, "data": c})),
            Ok(_) => None,
            Err(_) => Some(json!({"kind": kind, "id": id, "deleted": true})),
        },
        "event" => match db.event(id) {
            Ok(e) if is_local_calendar(db, &e.calendar_id) => Some(json!({"kind": kind, "id": id, "updated": e.updated, "data": e})),
            Ok(_) => None,
            Err(_) => Some(json!({"kind": kind, "id": id, "deleted": true})),
        },
        "task" => match db.task(id) {
            Ok(t) if is_local_calendar(db, &t.list_id) => Some(json!({"kind": kind, "id": id, "updated": t.updated, "data": t})),
            Ok(_) => None,
            Err(_) => Some(json!({"kind": kind, "id": id, "deleted": true})),
        },
        "attachment" => match db.attachment(id) {
            Ok((a, data)) => {
                let cal = match a.owner_kind.as_str() {
                    "event" => db.event(&a.owner_id).map(|e| e.calendar_id).ok(),
                    _ => db.task(&a.owner_id).map(|t| t.list_id).ok(),
                };
                if cal.map(|c| is_local_calendar(db, &c)).unwrap_or(false) {
                    Some(json!({"kind": kind, "id": id, "data": a, "content": data.map(|d| B64.encode(d))}))
                } else {
                    None
                }
            }
            Err(_) => Some(json!({"kind": kind, "id": id, "deleted": true})),
        },
        _ => None,
    })
}

/// Anota todo lo local para subirlo (primera sincronización de un equipo con datos).
fn enqueue_all(db: &Db) -> Result<()> {
    let at = time::now_utc_string();
    db.conn.execute_batch(&format!(
        "INSERT INTO changes(entity, entity_id, op, at)
           SELECT 'calendar', id, 'upsert', '{at}' FROM calendars WHERE source='local';
         INSERT INTO changes(entity, entity_id, op, at)
           SELECT 'event', id, 'upsert', '{at}' FROM events WHERE deleted=0 AND calendar_id IN (SELECT id FROM calendars WHERE source='local');
         INSERT INTO changes(entity, entity_id, op, at)
           SELECT 'task', id, 'upsert', '{at}' FROM tasks WHERE deleted=0 AND list_id IN (SELECT id FROM calendars WHERE source='local');
         INSERT INTO changes(entity, entity_id, op, at)
           SELECT 'attachment', id, 'upsert', '{at}' FROM attachments;"
    ))?;
    Ok(())
}

/// Elementos con cambios locales aún no subidos (para resolver conflictos).
fn pending(db: &Db, since: i64) -> Result<HashMap<(String, String), ()>> {
    let mut st = db.conn.prepare("SELECT entity, entity_id FROM changes WHERE seq > ?1")?;
    let rows = st.query_map(params![since], |r| Ok(((r.get::<_, String>(0)?, r.get::<_, String>(1)?), ())))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

fn stamp(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_digit()).collect()
}

/// Aplica en local un elemento recibido del servidor.
fn apply(db: &Db, item: &Value, st: &mut ZkStats) -> Result<()> {
    let kind = item.get("kind").and_then(|k| k.as_str()).unwrap_or("");
    let id = item.get("id").and_then(|k| k.as_str()).unwrap_or("").to_string();
    if item.get("deleted").and_then(|d| d.as_bool()).unwrap_or(false) {
        let existed = match kind {
            "calendar" => db.calendar(&id).map(|c| c.source == SOURCE_LOCAL).unwrap_or(false) && db.delete_calendar(&id).is_ok(),
            "event" => db.event(&id).is_ok() && db.delete_event(&id).is_ok(),
            "task" => db.task(&id).is_ok() && db.delete_task(&id).is_ok(),
            "attachment" => db.attachment(&id).is_ok() && db.delete_attachment(&id).is_ok(),
            _ => false,
        };
        if existed {
            st.deleted += 1;
        }
        return Ok(());
    }
    let data = item.get("data").cloned().unwrap_or(Value::Null);
    match kind {
        "calendar" => {
            let mut c: Calendar = serde_json::from_value(data)?;
            c.source = SOURCE_LOCAL.into();
            c.account_id = None;
            c.remote_url = None;
            c.ics_path = None;
            db.save_calendar(&mut c)?;
        }
        "event" => {
            let mut e: Event = serde_json::from_value(data)?;
            if db.calendar(&e.calendar_id).is_err() {
                return Ok(()); // su calendario no está (ni llegará): se ignora
            }
            db.save_event(&mut e, false)?;
        }
        "task" => {
            let mut t: Task = serde_json::from_value(data)?;
            if db.calendar(&t.list_id).is_err() {
                return Ok(());
            }
            db.save_task(&mut t, false)?;
        }
        "attachment" => {
            let a: Attachment = serde_json::from_value(data)?;
            let content = match item.get("content").and_then(|c| c.as_str()) {
                Some(c) => Some(B64.decode(c).map_err(|e| Error::Sync(format!("adjunto dañado: {e}")))?),
                None => None,
            };
            db.save_attachment(&a, content.as_deref())?;
        }
        _ => return Ok(()),
    }
    st.downloaded += 1;
    Ok(())
}

/// Orden para aplicar: calendarios, eventos, tareas madre, subtareas, adjuntos; los borrados al final.
fn apply_order(v: &Value) -> u8 {
    let deleted = v.get("deleted").and_then(|d| d.as_bool()).unwrap_or(false);
    let base = match v.get("kind").and_then(|k| k.as_str()).unwrap_or("") {
        "calendar" => 0,
        "event" => 1,
        "task" if v.pointer("/data/parentId").map(|p| p.is_null()).unwrap_or(true) => 2,
        "task" => 3,
        _ => 4,
    };
    if deleted { 10 + (4 - base) } else { base }
}

/// Sincroniza una cuenta: descarga lo nuevo del servidor, lo aplica y sube los cambios locales.
pub fn sync(db: &Db, acc: &mut ZkAccount, first: bool) -> Result<ZkStats> {
    let key = key32(&acc.key)?;
    let active = endpoints::pick(&acc.urls, acc.active_url.as_deref(), check)?;
    acc.active_url = Some(active.clone());
    let h = Http::new(&active, Some(&acc.token), Duration::from_secs(120))?;
    let mut st = ZkStats::default();

    // 1) Descarga (todas las páginas) y descifrado.
    let mut items: Vec<Value> = vec![];
    let mut since = acc.last_seq;
    let mut latest = since;
    loop {
        let r = h.get(&format!("/v1/changes?since={since}"))?;
        let page = r.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default();
        latest = r.get("latest").and_then(|l| l.as_i64()).unwrap_or(latest);
        for it in &page {
            let bid = it.get("id").and_then(|i| i.as_str()).unwrap_or("");
            since = since.max(it.get("seq").and_then(|s| s.as_i64()).unwrap_or(since));
            let Some(data) = it.get("data").and_then(|d| d.as_str()) else { continue };
            // Un bloque que no se puede descifrar (dañado o de otra clave) se ignora.
            if let Ok(v) = decrypt(&key, bid, data) {
                items.push(v);
            }
        }
        if !r.get("more").and_then(|m| m.as_bool()).unwrap_or(false) || page.is_empty() {
            break;
        }
    }

    // 2) Aplicar sin anotarlo como cambio local (para no reenviarlo). Gana la edición más reciente.
    // Primera vez: lo que ya había en este equipo se anota antes, para subirlo después sin reenviar lo recibido.
    if first {
        enqueue_all(db)?;
    }
    let local_pending = pending(db, acc.pushed_seq)?;
    items.sort_by_key(apply_order);
    db.suppress_log.set(true);
    let res = (|| -> Result<()> {
        for it in &items {
            let kind = it.get("kind").and_then(|k| k.as_str()).unwrap_or("").to_string();
            let id = it.get("id").and_then(|k| k.as_str()).unwrap_or("").to_string();
            if local_pending.contains_key(&(kind.clone(), id.clone())) {
                let remote_deleted = it.get("deleted").and_then(|d| d.as_bool()).unwrap_or(false);
                let local = match kind.as_str() {
                    "event" => db.event(&id).map(|e| Some(e.updated)).unwrap_or(None),
                    "task" => db.task(&id).map(|t| Some(t.updated)).unwrap_or(None),
                    "calendar" => db.calendar(&id).map(|_| Some(String::new())).unwrap_or(None),
                    "attachment" => db.attachment(&id).map(|_| Some(String::new())).unwrap_or(None),
                    _ => None,
                };
                match local {
                    // Borrado aquí y aún sin subir: gana el borrado.
                    None if !remote_deleted => {
                        st.conflicts += 1;
                        continue;
                    }
                    // Editado aquí: gana la versión más reciente.
                    Some(local_updated) if !remote_deleted && !local_updated.is_empty() => {
                        let remote_updated = it.get("updated").and_then(|u| u.as_str()).unwrap_or("");
                        if stamp(&local_updated) >= stamp(remote_updated) {
                            st.conflicts += 1;
                            continue;
                        }
                    }
                    _ => {}
                }
            }
            apply(db, it, &mut st)?;
        }
        Ok(())
    })();
    // Primera sincronización de un equipo que se une a una cuenta: sus calendarios vacíos que se llaman
    // igual que uno recibido (p. ej. los «Personal» y «Trabajo» que crea cada bóveda nueva) sobran.
    let res = res.and_then(|_| {
        if !first {
            return Ok(());
        }
        let pulled: Vec<(String, String)> = items
            .iter()
            .filter(|i| i.get("kind").and_then(|k| k.as_str()) == Some("calendar") && i.get("deleted").is_none())
            .filter_map(|i| Some((i.get("id")?.as_str()?.to_string(), i.pointer("/data/name")?.as_str()?.to_lowercase())))
            .collect();
        for c in db.calendars()?.into_iter().filter(|c| c.source == SOURCE_LOCAL) {
            if pulled.iter().any(|(id, _)| *id == c.id) {
                continue;
            }
            let empty: i64 = db.conn.query_row(
                "SELECT (SELECT count(*) FROM events WHERE calendar_id=?1) + (SELECT count(*) FROM tasks WHERE list_id=?1)",
                params![c.id],
                |r| r.get(0),
            )?;
            if empty == 0 && pulled.iter().any(|(_, n)| *n == c.name.to_lowercase()) {
                db.delete_calendar(&c.id)?;
            }
        }
        Ok(())
    });
    db.suppress_log.set(false);
    res?;
    acc.last_seq = latest.max(since);

    // 3) Subida de los cambios locales pendientes.
    let max_seq: i64 = db.conn.query_row("SELECT IFNULL(MAX(seq), 0) FROM changes", [], |r| r.get(0))?;
    let mut st_ = db.conn.prepare("SELECT entity, entity_id FROM changes WHERE seq > ?1 AND seq <= ?2 ORDER BY seq")?;
    let mut seen: Vec<(String, String)> = vec![];
    for r in st_.query_map(params![acc.pushed_seq, max_seq], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let k = r?;
        if let Some(pos) = seen.iter().position(|x| *x == k) {
            seen.remove(pos);
        }
        seen.push(k);
    }
    drop(st_);
    let mut batch: Vec<Value> = vec![];
    let mut size = 0usize;
    // Si las secuencias que asigna el servidor siguen justo a las ya descargadas, nadie subió nada
    // entretanto y se puede avanzar el contador sin volver a descargar lo propio.
    let mut expected = acc.last_seq;
    let mut contiguous = true;
    let mut flush = |batch: &mut Vec<Value>, size: &mut usize| -> Result<()> {
        if batch.is_empty() {
            return Ok(());
        }
        let r = h.post("/v1/push", &json!({"items": batch}))?;
        let seqs: Vec<i64> = r.get("seqs").and_then(|s| s.as_array()).map(|a| a.iter().filter_map(|x| x.as_i64()).collect()).unwrap_or_default();
        if seqs.first() == Some(&(expected + 1)) {
            expected = *seqs.last().unwrap();
        } else {
            contiguous = false;
        }
        batch.clear();
        *size = 0;
        Ok(())
    };
    for (kind, id) in seen {
        let Some(p) = payload(db, &kind, &id)? else { continue };
        let bid = blob_id(&key, &kind, &id);
        let data = encrypt(&key, &bid, &p)?;
        let deleted = p.get("deleted").and_then(|d| d.as_bool()).unwrap_or(false);
        size += data.len();
        batch.push(json!({"id": bid, "deleted": deleted, "data": data}));
        st.uploaded += 1;
        if size > PUSH_BYTES {
            flush(&mut batch, &mut size)?;
        }
    }
    flush(&mut batch, &mut size)?;
    acc.pushed_seq = max_seq;
    if contiguous {
        acc.last_seq = expected;
    }
    Ok(st)
}

/// Sincroniza una o todas las cuentas ZK con una conexión propia (no bloquea la interfaz).
pub fn sync_all(path: &Path, password: &str, account_id: Option<&str>) -> Result<Vec<(String, std::result::Result<ZkStats, String>)>> {
    let db = Db::open(path, password)?;
    let mut out = vec![];
    for mut acc in accounts(&db)?.into_iter().filter(|a| account_id.map(|id| id == a.id).unwrap_or(true)) {
        let first = acc.last_sync.is_none();
        let res = sync(&db, &mut acc, first);
        match &res {
            Ok(_) => {
                acc.last_sync = Some(time::now_utc_string());
                acc.last_error = None;
            }
            Err(e) => acc.last_error = Some(e.to_string()),
        }
        save_account(&db, &acc)?;
        out.push((acc.id.clone(), res.map_err(|e| e.to_string())));
    }
    Ok(out)
}

/// Comprueba si existe una cuenta ZK en esta bóveda (para la interfaz).
pub fn has_accounts(db: &Db) -> bool {
    db.conn.query_row("SELECT 1 FROM zk_accounts LIMIT 1", [], |_| Ok(())).optional().ok().flatten().is_some()
}
