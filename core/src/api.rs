//! API JSON que consume la interfaz Flutter (vía FFI). Una petición: {"method": "...", "params": {...}}.
//! Respuesta: {"ok": true, "data": ...} o {"ok": false, "error": "..."}.
use crate::backup;
use crate::error::{Error, Result};
use crate::model::*;
use crate::nlp;
use crate::time;
use crate::vault::{self, TaskFilter, Vault};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

static VAULT: Mutex<Option<Vault>> = Mutex::new(None);

const KEYRING_SERVICE: &str = "calendario-y-tareas";

fn keyring_entry(path: &Path) -> Result<keyring::Entry> {
    let user = format!("vault:{}", path.display());
    keyring::Entry::new(KEYRING_SERVICE, &user).map_err(|e| Error::Keyring(e.to_string()))
}

fn p<T: DeserializeOwned>(params: &Value, key: &str) -> Result<T> {
    serde_json::from_value(params.get(key).cloned().unwrap_or(Value::Null))
        .map_err(|e| Error::Invalid(format!("parámetro «{key}»: {e}")))
}

fn opt<T: DeserializeOwned>(params: &Value, key: &str) -> Option<T> {
    params.get(key).cloned().filter(|v| !v.is_null()).and_then(|v| serde_json::from_value(v).ok())
}

fn with<T>(f: impl FnOnce(&mut Vault) -> Result<T>) -> Result<T> {
    let mut g = VAULT.lock().unwrap_or_else(|e| e.into_inner());
    let v = g.as_mut().ok_or(Error::Locked)?;
    f(v)
}

pub fn handle(request: &str) -> String {
    let out = match serde_json::from_str::<Value>(request) {
        Ok(req) => {
            let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("").to_string();
            let params = req.get("params").cloned().unwrap_or(json!({}));
            dispatch(&method, &params)
        }
        Err(e) => Err(Error::Invalid(format!("petición no válida: {e}"))),
    };
    match out {
        Ok(data) => json!({"ok": true, "data": data}).to_string(),
        Err(e) => json!({"ok": false, "error": e.to_string(), "code": code(&e)}).to_string(),
    }
}

fn code(e: &Error) -> &'static str {
    match e {
        Error::WrongPassword => "wrong_password",
        Error::Locked => "locked",
        Error::NotFound(_) => "not_found",
        Error::Invalid(_) => "invalid",
        Error::Net(_) => "offline",
        Error::CalDav(_) => "caldav",
        Error::Sync(_) => "sync",
        _ => "error",
    }
}

fn dispatch(method: &str, a: &Value) -> Result<Value> {
    Ok(match method {
        // ------------------------------------------------------------ bóveda
        "sys.version" => json!({"version": env!("CARGO_PKG_VERSION"), "tz": time::system_tzid()}),
        "vault.exists" => {
            let path: PathBuf = p(a, "path")?;
            json!(path.exists())
        }
        "vault.create" => {
            let path: PathBuf = p(a, "path")?;
            let pw: String = p(a, "password")?;
            let v = Vault::create(&path, &pw)?;
            if opt::<bool>(a, "remember").unwrap_or(false) {
                let _ = keyring_entry(&path).and_then(|e| e.set_password(&pw).map_err(|e| Error::Keyring(e.to_string())));
            }
            *VAULT.lock().unwrap_or_else(|e| e.into_inner()) = Some(v);
            json!(true)
        }
        "vault.open" => {
            let path: PathBuf = p(a, "path")?;
            let pw: String = match opt::<String>(a, "password") {
                Some(pw) => pw,
                None => keyring_entry(&path)?
                    .get_password()
                    .map_err(|_| Error::Keyring("no hay contraseña guardada en este equipo".into()))?,
            };
            let v = Vault::open(&path, &pw)?;
            if opt::<bool>(a, "remember").unwrap_or(false) {
                let _ = keyring_entry(&path).and_then(|e| e.set_password(&pw).map_err(|e| Error::Keyring(e.to_string())));
            }
            *VAULT.lock().unwrap_or_else(|e| e.into_inner()) = Some(v);
            json!(true)
        }
        "vault.isOpen" => json!(VAULT.lock().unwrap_or_else(|e| e.into_inner()).is_some()),
        "vault.lock" => {
            *VAULT.lock().unwrap_or_else(|e| e.into_inner()) = None;
            Vault::clean_temp_attachments();
            json!(true)
        }
        "vault.remembered" => {
            let path: PathBuf = p(a, "path")?;
            json!(keyring_entry(&path).map(|e| e.get_password().is_ok()).unwrap_or(false))
        }
        "vault.forget" => {
            let path: PathBuf = p(a, "path")?;
            let _ = keyring_entry(&path).map(|e| e.delete_credential());
            json!(true)
        }
        "vault.remember" => with(|v| {
            let (path, pw) = v.credentials();
            keyring_entry(&path)?.set_password(&pw).map_err(|e| Error::Keyring(e.to_string()))?;
            Ok(json!(true))
        })?,
        "vault.changePassword" => with(|v| {
            let old: String = p(a, "old")?;
            let new: String = p(a, "new")?;
            v.change_password(&old, &new)?;
            let (path, _) = v.credentials();
            if let Ok(e) = keyring_entry(&path) {
                if e.get_password().is_ok() {
                    let _ = e.set_password(&new);
                }
            }
            Ok(json!(true))
        })?,
        "vault.relocate" => {
            // Mueve la bóveda a otra carpeta (modo portable o carpeta elegida) sin pedir de nuevo la contraseña.
            let new: PathBuf = p(a, "path")?;
            let mut g = VAULT.lock().unwrap_or_else(|e| e.into_inner());
            let v = g.take().ok_or(Error::Locked)?;
            let (old, pw) = v.credentials();
            drop(v); // cierra la conexión: SQLite vuelca el WAL al archivo principal
            let res = relocate_files(&old, &new);
            match res {
                Ok(()) => {
                    if let Ok(e) = keyring_entry(&old) {
                        if e.get_password().is_ok() {
                            let _ = e.delete_credential();
                            let _ = keyring_entry(&new).and_then(|n| n.set_password(&pw).map_err(|e| Error::Keyring(e.to_string())));
                        }
                    }
                    *g = Some(Vault::open(&new, &pw)?);
                    json!(new.display().to_string())
                }
                Err(e) => {
                    *g = Some(Vault::open(&old, &pw)?);
                    return Err(e);
                }
            }
        }
        "vault.info" => with(|v| {
            Ok(json!({
                "path": v.path.display().to_string(),
                "tz": time::system_tzid(),
                "pending": v.db.pending_changes()?,
                "dataVersion": v.db.data_version()?,
            }))
        })?,
        "vault.dataVersion" => with(|v| Ok(json!(v.db.data_version()?)))?,

        // ------------------------------------------------------------ calendarios
        "calendars.list" => with(|v| Ok(json!(v.db.calendars()?)))?,
        "calendars.save" => with(|v| {
            let mut c: Calendar = p(a, "calendar")?;
            if c.name.trim().is_empty() {
                return Err(Error::Invalid("el calendario necesita un nombre".into()));
            }
            if c.id.is_empty() {
                c.position = v.db.calendars()?.len() as i64;
            } else {
                // Los campos de origen no se cambian desde la interfaz.
                let old = v.db.calendar(&c.id)?;
                c.source = old.source;
                c.ics_path = old.ics_path;
                c.account_id = old.account_id;
                c.remote_url = old.remote_url;
                c.ctag = old.ctag;
            }
            v.db.save_calendar(&mut c)?;
            Ok(json!(c))
        })?,
        "calendars.delete" => with(|v| {
            let id: String = p(a, "id")?;
            v.db.delete_calendar(&id)?;
            Ok(json!(true))
        })?,

        // ------------------------------------------------------------ eventos
        "events.range" => with(|v| Ok(json!(v.range(&p::<String>(a, "from")?, &p::<String>(a, "to")?)?)))?,
        "events.get" => with(|v| Ok(json!(v.db.event(&p::<String>(a, "id")?)?)))?,
        "events.save" => with(|v| {
            let e: Event = p(a, "event")?;
            let scope = opt::<String>(a, "scope").unwrap_or_else(|| "all".into());
            let occ = opt::<String>(a, "occurrence");
            Ok(json!(v.save_event(e, &scope, occ.as_deref())?))
        })?,
        "events.delete" => with(|v| {
            let scope = opt::<String>(a, "scope").unwrap_or_else(|| "all".into());
            let occ = opt::<String>(a, "occurrence");
            v.delete_event(&p::<String>(a, "id")?, &scope, occ.as_deref())?;
            Ok(json!(true))
        })?,
        "events.quickAdd" => with(|v| Ok(json!(v.quick_event(&p::<String>(a, "text")?, &p::<String>(a, "calendarId")?)?)))?,

        // ------------------------------------------------------------ tareas
        "tasks.list" => with(|v| {
            let f: TaskFilter = opt(a, "filter").unwrap_or_default();
            Ok(json!(v.tasks(&f)?))
        })?,
        "tasks.range" => with(|v| Ok(json!(v.tasks_in_range(&p::<String>(a, "from")?, &p::<String>(a, "to")?)?)))?,
        "tasks.counts" => with(|v| Ok(json!(v.counts()?)))?,
        "tasks.get" => with(|v| Ok(json!(v.db.task(&p::<String>(a, "id")?)?)))?,
        "tasks.save" => with(|v| Ok(json!(v.save_task(p(a, "task")?)?)))?,
        "tasks.toggle" => with(|v| Ok(json!(v.toggle_task(&p::<String>(a, "id")?)?)))?,
        "tasks.delete" => with(|v| {
            v.delete_task(&p::<String>(a, "id")?)?;
            Ok(json!(true))
        })?,
        "tasks.quickAdd" => with(|v| {
            Ok(json!(v.quick_task(&p::<String>(a, "text")?, &p::<String>(a, "listId")?, opt(a, "parentId"))?))
        })?,
        "attachments.list" => with(|v| Ok(json!(v.db.attachments(&p::<String>(a, "ownerId")?)?)))?,
        "attachments.add" => {
            // Leer un documento grande puede tardar: se hace con la bóveda bloqueada, pero desde un isolate.
            with(|v| {
                let target: String = opt(a, "path").or_else(|| opt(a, "url")).unwrap_or_default();
                let name: Option<String> = opt(a, "name");
                Ok(json!(v.add_attachment(&p::<String>(a, "ownerKind")?, &p::<String>(a, "ownerId")?, &p::<String>(a, "kind")?, &target, name.as_deref())?))
            })?
        }
        "attachments.delete" => with(|v| {
            v.db.delete_attachment(&p::<String>(a, "id")?)?;
            Ok(json!(true))
        })?,
        "attachments.open" => with(|v| Ok(json!(v.open_attachment(&p::<String>(a, "id")?)?)))?,
        "attachments.export" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            v.export_attachment(&p::<String>(a, "id")?, &path)?;
            Ok(json!(true))
        })?,
        "tags.list" => with(|v| Ok(json!(v.db.tags()?)))?,
        "search" => with(|v| {
            let (events, tasks) = v.db.search(&p::<String>(a, "q")?)?;
            Ok(json!({"events": events, "tasks": tasks}))
        })?,
        "nlp.parse" => {
            let text: String = p(a, "text")?;
            json!(nlp::parse(&text, time::now_local(&time::system_tzid())))
        }
        "alarms.between" => with(|v| Ok(json!(v.alarms_between(&p::<String>(a, "from")?, &p::<String>(a, "to")?)?)))?,

        // ------------------------------------------------------------ .ics
        "ics.import" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            let cid = opt::<String>(a, "calendarId");
            let (cal, n) = v.import_ics(&path, cid.as_deref())?;
            Ok(json!({"calendar": cal, "count": n}))
        })?,
        "ics.link" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            let (cal, n) = v.link_ics(&path, opt(a, "readonly").unwrap_or(false))?;
            Ok(json!({"calendar": cal, "count": n}))
        })?,
        "ics.export" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            Ok(json!(v.export_ics(&p::<String>(a, "calendarId")?, &path)?))
        })?,
        "ics.refresh" => with(|v| Ok(json!(v.refresh_ics()?)))?,

        // ------------------------------------------------------------ CalDAV
        "caldav.accounts" => with(|v| Ok(json!(v.db.accounts()?)))?,
        "caldav.add" => {
            // El descubrimiento usa la red: se hace sin retener el bloqueo de la bóveda.
            let name: String = opt(a, "name").unwrap_or_default();
            let urls = urls_param(a)?;
            let user: String = p(a, "username")?;
            let pass: String = p(a, "password")?;
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let tmp = Vault::open(&path, &pw)?;
            let (acc, cals) = tmp.add_caldav(&name, &urls, &user, &pass)?;
            drop(tmp);
            let res = vault::sync_accounts(&path, &pw, Some(&acc.id))?;
            json!({"account": acc, "calendars": cals, "sync": sync_json(res)})
        }
        "caldav.test" => {
            // Prueba cada dirección indicada (o las de una cuenta guardada) y devuelve el resultado de cada una.
            let (urls, user, pass) = match opt::<String>(a, "accountId") {
                Some(id) => {
                    let acc = with(|v| v.db.account(&id))?;
                    let urls = opt::<Vec<String>>(a, "urls").unwrap_or_else(|| acc.urls());
                    let pass = opt::<String>(a, "password").filter(|p| !p.is_empty()).unwrap_or(acc.password);
                    (urls, opt::<String>(a, "username").filter(|u| !u.is_empty()).unwrap_or(acc.username), pass)
                }
                None => (urls_param(a)?, p(a, "username")?, p(a, "password")?),
            };
            let urls = crate::endpoints::normalize(&urls)?;
            let dav = crate::caldav::Dav::quick(&user, &pass)?;
            let probes: Vec<_> = urls.iter().map(|u| crate::endpoints::probe(u, |x| crate::caldav::check(&dav, x))).collect();
            json!(probes)
        }
        "caldav.update" => with(|v| {
            let urls: Option<Vec<String>> = opt(a, "urls");
            let name: Option<String> = opt(a, "name");
            let user: Option<String> = opt(a, "username");
            let pass: Option<String> = opt(a, "password");
            Ok(json!(v.update_caldav(&p::<String>(a, "id")?, name.as_deref(), urls.as_deref(), user.as_deref(), pass.as_deref())?))
        })?,
        // ------------------------------------------------------------ servidor zero-knowledge
        "zk.accounts" => with(|v| Ok(json!(crate::zk::accounts(&v.db)?)))?,
        "zk.test" => json!(crate::zk::test(&urls_param(a)?)?),
        "zk.register" | "zk.login" | "zk.recover" => {
            // Operaciones de red y Argon2: con una conexión propia, sin retener la bóveda.
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let db = crate::db::Db::open(&path, &pw)?;
            let name: String = opt(a, "name").unwrap_or_default();
            let urls = urls_param(a)?;
            let user: String = p(a, "username")?;
            let linked = match method {
                "zk.register" => crate::zk::register(&db, &name, &urls, &user, &p::<String>(a, "password")?)?,
                "zk.login" => crate::zk::login(&db, &name, &urls, &user, &p::<String>(a, "password")?)?,
                _ => crate::zk::recover(&db, &name, &urls, &user, &p::<String>(a, "recoveryCode")?, &p::<String>(a, "password")?)?,
            };
            drop(db);
            let sync = crate::zk::sync_all(&path, &pw, Some(&linked.account.id))?;
            json!({"account": linked.account, "recoveryCode": linked.recovery_code, "sync": zk_json(sync)})
        }
        "zk.sync" => {
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let id = opt::<String>(a, "accountId");
            zk_json(crate::zk::sync_all(&path, &pw, id.as_deref())?)
        }
        "zk.changePassword" => {
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let db = crate::db::Db::open(&path, &pw)?;
            crate::zk::change_password(&db, &p::<String>(a, "id")?, &p::<String>(a, "password")?)?;
            json!(true)
        }
        "zk.update" => with(|v| {
            let urls: Option<Vec<String>> = opt(a, "urls");
            let name: Option<String> = opt(a, "name");
            Ok(json!(crate::zk::update_urls(&v.db, &p::<String>(a, "id")?, name.as_deref(), urls.as_deref())?))
        })?,
        "zk.remove" => {
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let db = crate::db::Db::open(&path, &pw)?;
            crate::zk::unlink(&db, &p::<String>(a, "id")?, opt(a, "deleteRemote").unwrap_or(false))?;
            json!(true)
        }
        "caldav.remove" => with(|v| {
            v.db.delete_account(&p::<String>(a, "id")?)?;
            Ok(json!(true))
        })?,
        "caldav.sync" => {
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let id = opt::<String>(a, "accountId");
            sync_json(vault::sync_accounts(&path, &pw, id.as_deref())?)
        }
        "caldav.createCalendar" => {
            let (path, pw) = with(|v| Ok(v.credentials()))?;
            let tmp = Vault::open(&path, &pw)?;
            let c = tmp.create_remote_calendar(
                &p::<String>(a, "accountId")?,
                &p::<String>(a, "name")?,
                &opt::<String>(a, "color").unwrap_or("#007AFF".into()),
                &opt::<String>(a, "kind").unwrap_or("both".into()),
            )?;
            json!(c)
        }

        // ------------------------------------------------------------ copias de seguridad
        "backup.create" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            Ok(json!(backup::create(&v.db, &path, &p::<String>(a, "password")?)?))
        })?,
        "backup.inspect" => {
            let path: PathBuf = p(a, "path")?;
            json!(backup::inspect(&path, &p::<String>(a, "password")?)?)
        }
        "backup.restore" => with(|v| {
            let path: PathBuf = p(a, "path")?;
            let replace = opt::<bool>(a, "replace").unwrap_or(false);
            Ok(json!(backup::restore(&mut v.db, &path, &p::<String>(a, "password")?, replace)?))
        })?,

        // ------------------------------------------------------------ sistema
        "sys.pinToDesktop" => {
            let title: String = p(a, "title")?;
            json!(crate::desktop::pin_to_desktop(&title)?)
        }
        "sys.pickFile" => {
            let mode: String = opt(a, "mode").unwrap_or_else(|| "open".into());
            let title: String = opt(a, "title").unwrap_or_default();
            let exts: Vec<String> = opt(a, "extensions").unwrap_or_default();
            let fname: String = opt(a, "filterName").unwrap_or_else(|| "Archivos".into());
            let def: Option<String> = opt(a, "defaultName");
            json!(crate::desktop::pick_file(&mode, &title, &fname, &exts, def.as_deref()))
        }
        "sys.singleInstance" => json!(crate::desktop::single_instance(&p::<String>(a, "key")?)),
        "sys.allowForeground" => json!(crate::desktop::allow_foreground()),
        "sys.notify" => json!(crate::desktop::notify(&p::<String>(a, "title")?, &opt::<String>(a, "body").unwrap_or_default())?),
        _ => return Err(Error::Invalid(format!("método desconocido: {method}"))),
    })
}

/// Mueve el archivo de la bóveda (y sus ficheros WAL si quedaran) a `new`. Funciona entre discos distintos.
fn relocate_files(old: &Path, new: &Path) -> Result<()> {
    if new == old {
        return Ok(());
    }
    if new.exists() {
        return Err(Error::Invalid("en esa carpeta ya hay unos datos de Calendario y Tareas".into()));
    }
    if let Some(dir) = new.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mv = |from: &Path, to: &Path| -> Result<()> {
        if std::fs::rename(from, to).is_err() {
            std::fs::copy(from, to)?;
            std::fs::remove_file(from)?;
        }
        Ok(())
    };
    mv(old, new)?;
    for ext in ["-wal", "-shm"] {
        let from = PathBuf::from(format!("{}{ext}", old.display()));
        if from.exists() {
            let _ = mv(&from, &PathBuf::from(format!("{}{ext}", new.display())));
        }
    }
    Ok(())
}

fn sync_json(res: Vec<(String, std::result::Result<crate::caldav::SyncStats, String>)>) -> Value {
    Value::Array(
        res.into_iter()
            .map(|(id, r)| match r {
                Ok(s) => json!({"accountId": id, "ok": true, "stats": s}),
                Err(e) => json!({"accountId": id, "ok": false, "error": e}),
            })
            .collect(),
    )
}

/// Direcciones de una petición: `urls` (lista) o `url` (una sola, versiones anteriores).
fn urls_param(a: &Value) -> Result<Vec<String>> {
    if let Some(v) = opt::<Vec<String>>(a, "urls") {
        return Ok(v);
    }
    Ok(vec![p::<String>(a, "url")?])
}

fn zk_json(res: Vec<(String, std::result::Result<crate::zk::ZkStats, String>)>) -> Value {
    Value::Array(
        res.into_iter()
            .map(|(id, r)| match r {
                Ok(s) => json!({"accountId": id, "ok": true, "stats": s}),
                Err(e) => json!({"accountId": id, "ok": false, "error": e}),
            })
            .collect(),
    )
}
