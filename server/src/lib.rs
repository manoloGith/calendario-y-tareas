//! Servidor de sincronización «zero-knowledge» de Calendario y Tareas.
//!
//! El servidor nunca ve datos en claro: guarda bloques cifrados por el cliente (XChaCha20-Poly1305 con una
//! clave de cuenta que solo conocen los dispositivos) y les asigna un número de secuencia para que cada
//! dispositivo descargue lo que le falta. Tampoco conoce la contraseña: el cliente deriva de ella, con
//! Argon2id, una clave de acceso (que es lo único que se envía) y otra de cifrado (que nunca sale del equipo).
use axum::extract::{DefaultBodyLimit, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL};
use base64::Engine;
use hmac::{Hmac, Mac};
use rand::RngCore;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Tamaño máximo de una petición (los adjuntos van dentro de los bloques).
const MAX_BODY: usize = 160 * 1024 * 1024;
/// Máximo de bytes de datos devueltos en una página de cambios.
const PAGE_BYTES: usize = 24 * 1024 * 1024;
const SESSION_DAYS: i64 = 180;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  salt BLOB NOT NULL, auth_salt BLOB NOT NULL, auth_verifier BLOB NOT NULL, wrapped_key TEXT NOT NULL,
  recovery_salt BLOB NOT NULL, recovery_verifier BLOB NOT NULL, recovery_wrapped TEXT NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash BLOB PRIMARY KEY, user_id INTEGER NOT NULL, device TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL, last_used INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blobs (
  user_id INTEGER NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  data BLOB, updated INTEGER NOT NULL, PRIMARY KEY (user_id, id)
);
CREATE INDEX IF NOT EXISTS blobs_seq ON blobs(user_id, seq);
"#;

pub struct Inner {
    db: Mutex<Connection>,
    secret: Vec<u8>,
    allow_register: bool,
    failures: Mutex<HashMap<String, (u32, Instant)>>,
}

pub type AppState = Arc<Inner>;

pub struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}

type ApiResult<T> = Result<T, ApiError>;

fn bad(msg: &str) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, msg.into())
}
fn unauthorized() -> ApiError {
    ApiError(StatusCode::UNAUTHORIZED, "sesión no válida".into())
}
fn internal<E: std::fmt::Display>(e: E) -> ApiError {
    ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("error interno: {e}"))
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn random(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut v);
    v
}

fn sha256(parts: &[&[u8]]) -> Vec<u8> {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().to_vec()
}

/// Comparación en tiempo constante.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn b64(s: &str, expected: Option<usize>, what: &str) -> ApiResult<Vec<u8>> {
    let v = B64.decode(s.trim()).map_err(|_| bad(&format!("{what}: base64 no válido")))?;
    if let Some(n) = expected {
        if v.len() != n {
            return Err(bad(&format!("{what}: longitud incorrecta")));
        }
    }
    Ok(v)
}

fn valid_username(u: &str) -> bool {
    (3..=64).contains(&u.chars().count()) && u.chars().all(|c| c.is_ascii_alphanumeric() || "._@-".contains(c))
}

/// Abre (o crea) la base de datos del servidor.
pub fn open(path: &Path, allow_register: bool) -> rusqlite::Result<AppState> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.execute_batch(SCHEMA)?;
    let secret: Vec<u8> = match conn.query_row("SELECT value FROM meta WHERE key='secret'", [], |r| r.get(0)).optional()? {
        Some(s) => s,
        None => {
            let s = random(32);
            conn.execute("INSERT INTO meta(key, value) VALUES('secret', ?1)", params![s])?;
            s
        }
    };
    Ok(Arc::new(Inner { db: Mutex::new(conn), secret, allow_register, failures: Mutex::new(HashMap::new()) }))
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/prelogin", post(prelogin))
        .route("/v1/register", post(register))
        .route("/v1/login", post(login))
        .route("/v1/recover", post(recover))
        .route("/v1/password", post(password))
        .route("/v1/logout", post(logout))
        .route("/v1/changes", get(changes))
        .route("/v1/push", post(push))
        .route("/v1/account", axum::routing::delete(delete_account))
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(state)
}

async fn health(State(st): State<AppState>) -> Json<Value> {
    Json(json!({"ok": true, "service": "calendario-zk", "version": VERSION, "registration": st.allow_register}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreloginReq {
    username: String,
}

/// Devuelve la sal de la cuenta para derivar las claves. Para usuarios que no existen se devuelve una sal
/// estable pero falsa, para no revelar qué nombres de usuario existen.
async fn prelogin(State(st): State<AppState>, Json(r): Json<PreloginReq>) -> ApiResult<Json<Value>> {
    let db = st.db.lock().unwrap();
    let salt: Option<Vec<u8>> = db
        .query_row("SELECT salt FROM users WHERE username=?1", params![r.username], |x| x.get(0))
        .optional()
        .map_err(internal)?;
    let salt = salt.unwrap_or_else(|| {
        let mut m = Hmac::<Sha256>::new_from_slice(&st.secret).unwrap();
        m.update(r.username.to_lowercase().as_bytes());
        m.finalize().into_bytes()[..16].to_vec()
    });
    Ok(Json(json!({"salt": B64.encode(salt), "kdf": "argon2id-m65536-t3-p1"})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegisterReq {
    username: String,
    salt: String,
    auth_key: String,
    wrapped_key: String,
    recovery_auth_key: String,
    recovery_wrapped_key: String,
    #[serde(default)]
    device: String,
}

fn new_session(db: &Connection, user_id: i64, device: &str) -> ApiResult<String> {
    let token = random(32);
    let t = now();
    db.execute(
        "INSERT INTO sessions(token_hash, user_id, device, created, last_used) VALUES(?1,?2,?3,?4,?4)",
        params![sha256(&[&token]), user_id, device.chars().take(80).collect::<String>(), t],
    )
    .map_err(internal)?;
    Ok(B64URL.encode(token))
}

async fn register(State(st): State<AppState>, Json(r): Json<RegisterReq>) -> ApiResult<Json<Value>> {
    if !st.allow_register {
        return Err(ApiError(StatusCode::FORBIDDEN, "el registro de cuentas nuevas está desactivado en este servidor".into()));
    }
    if !valid_username(&r.username) {
        return Err(bad("nombre de usuario no válido (3-64 caracteres: letras, números y . _ @ -)"));
    }
    let salt = b64(&r.salt, Some(16), "salt")?;
    let auth = b64(&r.auth_key, Some(32), "authKey")?;
    let rauth = b64(&r.recovery_auth_key, Some(32), "recoveryAuthKey")?;
    if r.wrapped_key.len() > 2048 || r.recovery_wrapped_key.len() > 2048 {
        return Err(bad("clave envuelta demasiado larga"));
    }
    let (auth_salt, rec_salt) = (random(16), random(16));
    let db = st.db.lock().unwrap();
    let exists: bool = db
        .query_row("SELECT 1 FROM users WHERE username=?1", params![r.username], |_| Ok(true))
        .optional()
        .map_err(internal)?
        .is_some();
    if exists {
        return Err(ApiError(StatusCode::CONFLICT, "ese nombre de usuario ya existe".into()));
    }
    db.execute(
        "INSERT INTO users(username, salt, auth_salt, auth_verifier, wrapped_key, recovery_salt, recovery_verifier, recovery_wrapped, created)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![
            r.username, salt, auth_salt, sha256(&[&auth_salt, &auth]), r.wrapped_key,
            rec_salt, sha256(&[&rec_salt, &rauth]), r.recovery_wrapped_key, now()
        ],
    )
    .map_err(internal)?;
    let id = db.last_insert_rowid();
    let token = new_session(&db, id, &r.device)?;
    Ok(Json(json!({"token": token})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginReq {
    username: String,
    auth_key: String,
    #[serde(default)]
    device: String,
}

/// Limita los intentos fallidos por usuario (5 seguidos → espera de 60 s).
fn throttled(st: &Inner, user: &str) -> bool {
    let f = st.failures.lock().unwrap();
    matches!(f.get(&user.to_lowercase()), Some((n, t)) if *n >= 5 && t.elapsed() < Duration::from_secs(60))
}

fn record_failure(st: &Inner, user: &str, ok: bool) {
    let mut f = st.failures.lock().unwrap();
    let k = user.to_lowercase();
    if ok {
        f.remove(&k);
    } else {
        let e = f.entry(k).or_insert((0, Instant::now()));
        if e.1.elapsed() > Duration::from_secs(60) {
            e.0 = 0;
        }
        e.0 += 1;
        e.1 = Instant::now();
    }
}

async fn login(State(st): State<AppState>, Json(r): Json<LoginReq>) -> ApiResult<Json<Value>> {
    if throttled(&st, &r.username) {
        return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "demasiados intentos; espera un minuto".into()));
    }
    let auth = b64(&r.auth_key, Some(32), "authKey")?;
    let db = st.db.lock().unwrap();
    let row: Option<(i64, Vec<u8>, Vec<u8>, String)> = db
        .query_row("SELECT id, auth_salt, auth_verifier, wrapped_key FROM users WHERE username=?1", params![r.username], |x| {
            Ok((x.get(0)?, x.get(1)?, x.get(2)?, x.get(3)?))
        })
        .optional()
        .map_err(internal)?;
    let ok = matches!(&row, Some((_, s, v, _)) if same(&sha256(&[s, &auth]), v));
    record_failure(&st, &r.username, ok);
    let Some((id, _, _, wrapped)) = row.filter(|_| ok) else {
        return Err(ApiError(StatusCode::UNAUTHORIZED, "usuario o contraseña incorrectos".into()));
    };
    let token = new_session(&db, id, &r.device)?;
    Ok(Json(json!({"token": token, "wrappedKey": wrapped})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoverReq {
    username: String,
    recovery_auth_key: String,
    #[serde(default)]
    device: String,
}

/// Acceso con el código de recuperación (para fijar una contraseña nueva si se olvidó la anterior).
async fn recover(State(st): State<AppState>, Json(r): Json<RecoverReq>) -> ApiResult<Json<Value>> {
    if throttled(&st, &r.username) {
        return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "demasiados intentos; espera un minuto".into()));
    }
    let rauth = b64(&r.recovery_auth_key, Some(32), "recoveryAuthKey")?;
    let db = st.db.lock().unwrap();
    let row: Option<(i64, Vec<u8>, Vec<u8>, String)> = db
        .query_row("SELECT id, recovery_salt, recovery_verifier, recovery_wrapped FROM users WHERE username=?1", params![r.username], |x| {
            Ok((x.get(0)?, x.get(1)?, x.get(2)?, x.get(3)?))
        })
        .optional()
        .map_err(internal)?;
    let ok = matches!(&row, Some((_, s, v, _)) if same(&sha256(&[s, &rauth]), v));
    record_failure(&st, &r.username, ok);
    let Some((id, _, _, wrapped)) = row.filter(|_| ok) else {
        return Err(ApiError(StatusCode::UNAUTHORIZED, "usuario o código de recuperación incorrectos".into()));
    };
    let token = new_session(&db, id, &r.device)?;
    Ok(Json(json!({"token": token, "recoveryWrappedKey": wrapped})))
}

/// Identifica la sesión a partir de la cabecera `Authorization: Bearer <token>`.
fn session(st: &Inner, db: &Connection, h: &HeaderMap) -> ApiResult<(i64, Vec<u8>)> {
    let _ = st;
    let tok = h
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(unauthorized)?;
    let raw = B64URL.decode(tok.trim()).map_err(|_| unauthorized())?;
    let hash = sha256(&[&raw]);
    let t = now();
    let user: Option<i64> = db
        .query_row(
            "SELECT user_id FROM sessions WHERE token_hash=?1 AND last_used > ?2",
            params![hash, t - SESSION_DAYS * 86400],
            |x| x.get(0),
        )
        .optional()
        .map_err(internal)?;
    let user = user.ok_or_else(unauthorized)?;
    db.execute("UPDATE sessions SET last_used=?2 WHERE token_hash=?1", params![hash, t]).map_err(internal)?;
    Ok((user, hash))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasswordReq {
    auth_key: String,
    wrapped_key: String,
    #[serde(default)]
    recovery_auth_key: Option<String>,
    #[serde(default)]
    recovery_wrapped_key: Option<String>,
}

/// Cambia la contraseña: nueva clave de acceso y clave de cuenta envuelta con la nueva contraseña.
/// Cierra las demás sesiones.
async fn password(State(st): State<AppState>, h: HeaderMap, Json(r): Json<PasswordReq>) -> ApiResult<Json<Value>> {
    let auth = b64(&r.auth_key, Some(32), "authKey")?;
    let db = st.db.lock().unwrap();
    let (user, token_hash) = session(&st, &db, &h)?;
    let s = random(16);
    db.execute(
        "UPDATE users SET auth_salt=?2, auth_verifier=?3, wrapped_key=?4 WHERE id=?1",
        params![user, s, sha256(&[&s, &auth]), r.wrapped_key],
    )
    .map_err(internal)?;
    if let (Some(ra), Some(rw)) = (r.recovery_auth_key, r.recovery_wrapped_key) {
        let ra = b64(&ra, Some(32), "recoveryAuthKey")?;
        let rs = random(16);
        db.execute(
            "UPDATE users SET recovery_salt=?2, recovery_verifier=?3, recovery_wrapped=?4 WHERE id=?1",
            params![user, rs, sha256(&[&rs, &ra]), rw],
        )
        .map_err(internal)?;
    }
    db.execute("DELETE FROM sessions WHERE user_id=?1 AND token_hash<>?2", params![user, token_hash]).map_err(internal)?;
    Ok(Json(json!({"ok": true})))
}

async fn logout(State(st): State<AppState>, h: HeaderMap) -> ApiResult<Json<Value>> {
    let db = st.db.lock().unwrap();
    let (_, hash) = session(&st, &db, &h)?;
    db.execute("DELETE FROM sessions WHERE token_hash=?1", params![hash]).map_err(internal)?;
    Ok(Json(json!({"ok": true})))
}

async fn delete_account(State(st): State<AppState>, h: HeaderMap) -> ApiResult<Json<Value>> {
    let db = st.db.lock().unwrap();
    let (user, _) = session(&st, &db, &h)?;
    db.execute_batch("BEGIN").map_err(internal)?;
    for sql in ["DELETE FROM blobs WHERE user_id=?1", "DELETE FROM sessions WHERE user_id=?1", "DELETE FROM users WHERE id=?1"] {
        db.execute(sql, params![user]).map_err(internal)?;
    }
    db.execute_batch("COMMIT").map_err(internal)?;
    Ok(Json(json!({"ok": true})))
}

#[derive(Deserialize)]
struct ChangesQuery {
    #[serde(default)]
    since: i64,
    #[serde(default)]
    limit: Option<i64>,
}

/// Bloques modificados después de `since`, en orden. `more = true` si hay que pedir otra página.
async fn changes(State(st): State<AppState>, h: HeaderMap, Query(q): Query<ChangesQuery>) -> ApiResult<Json<Value>> {
    let db = st.db.lock().unwrap();
    let (user, _) = session(&st, &db, &h)?;
    let latest: i64 = db.query_row("SELECT seq FROM users WHERE id=?1", params![user], |x| x.get(0)).map_err(internal)?;
    let limit = q.limit.unwrap_or(1000).clamp(1, 5000);
    let mut st_ = db
        .prepare("SELECT id, seq, deleted, data FROM blobs WHERE user_id=?1 AND seq>?2 ORDER BY seq LIMIT ?3")
        .map_err(internal)?;
    let rows = st_
        .query_map(params![user, q.since, limit + 1], |x| {
            Ok((x.get::<_, String>(0)?, x.get::<_, i64>(1)?, x.get::<_, i64>(2)? != 0, x.get::<_, Option<Vec<u8>>>(3)?))
        })
        .map_err(internal)?;
    let mut items = vec![];
    let mut bytes = 0usize;
    let mut more = false;
    for r in rows {
        let (id, seq, deleted, data) = r.map_err(internal)?;
        if items.len() as i64 >= limit || (bytes > PAGE_BYTES && !items.is_empty()) {
            more = true;
            break;
        }
        bytes += data.as_ref().map(|d| d.len()).unwrap_or(0);
        items.push(json!({"id": id, "seq": seq, "deleted": deleted, "data": data.map(|d| B64.encode(d))}));
    }
    Ok(Json(json!({"items": items, "latest": latest, "more": more})))
}

#[derive(Deserialize)]
struct PushItem {
    id: String,
    #[serde(default)]
    deleted: bool,
    #[serde(default)]
    data: Option<String>,
}

#[derive(Deserialize)]
struct PushReq {
    items: Vec<PushItem>,
}

/// Guarda bloques nuevos o modificados (o lápidas de borrado). Cada uno recibe un número de secuencia.
async fn push(State(st): State<AppState>, h: HeaderMap, Json(r): Json<PushReq>) -> ApiResult<Json<Value>> {
    let mut db = st.db.lock().unwrap();
    let (user, _) = session(&st, &db, &h)?;
    for it in &r.items {
        if it.id.is_empty() || it.id.len() > 128 || !it.id.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(bad("identificador de bloque no válido"));
        }
        if !it.deleted && it.data.is_none() {
            return Err(bad("bloque sin datos"));
        }
    }
    let tx = db.transaction().map_err(internal)?;
    let mut seq: i64 = tx.query_row("SELECT seq FROM users WHERE id=?1", params![user], |x| x.get(0)).map_err(internal)?;
    let mut seqs = vec![];
    for it in r.items {
        seq += 1;
        // Las lápidas de borrado también pueden llevar datos cifrados (para que el cliente sepa qué borrar).
        let data = match &it.data {
            Some(d) => Some(b64(d, None, "data")?),
            None => None,
        };
        tx.execute(
            "INSERT INTO blobs(user_id, id, seq, deleted, data, updated) VALUES(?1,?2,?3,?4,?5,?6)
             ON CONFLICT(user_id, id) DO UPDATE SET seq=?3, deleted=?4, data=?5, updated=?6",
            params![user, it.id, seq, it.deleted as i64, data, now()],
        )
        .map_err(internal)?;
        seqs.push(seq);
    }
    tx.execute("UPDATE users SET seq=?2 WHERE id=?1", params![user, seq]).map_err(internal)?;
    tx.commit().map_err(internal)?;
    Ok(Json(json!({"seqs": seqs, "latest": seq})))
}
