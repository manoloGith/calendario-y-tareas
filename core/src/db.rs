//! Almacenamiento local cifrado (SQLCipher). Es la fuente de verdad de la app: todo se escribe aquí primero.
use crate::error::{Error, Result};
use crate::model::*;
use crate::time;
use rusqlite::{params, Connection, OptionalExtension, Row};
use std::path::Path;
use std::time::Duration;

pub const SCHEMA_VERSION: i64 = 1;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, base_url TEXT NOT NULL, username TEXT NOT NULL,
  password TEXT NOT NULL DEFAULT '', principal_url TEXT, home_url TEXT, last_sync TEXT, last_error TEXT
);
CREATE TABLE IF NOT EXISTS calendars (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'both',
  source TEXT NOT NULL DEFAULT 'local', visible INTEGER NOT NULL DEFAULT 1, position INTEGER NOT NULL DEFAULT 0,
  ics_path TEXT, account_id TEXT, remote_url TEXT, ctag TEXT, readonly INTEGER NOT NULL DEFAULT 0,
  ics_mtime INTEGER
);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY, calendar_id TEXT NOT NULL, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '', all_day INTEGER NOT NULL DEFAULT 0, start TEXT NOT NULL, end TEXT NOT NULL,
  tzid TEXT NOT NULL DEFAULT '', rrule TEXT, exdates TEXT NOT NULL DEFAULT '[]', alarms TEXT NOT NULL DEFAULT '[]',
  start_utc INTEGER NOT NULL, end_utc INTEGER NOT NULL,
  created TEXT NOT NULL, updated TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0, remote_href TEXT, etag TEXT
);
CREATE INDEX IF NOT EXISTS events_range ON events(calendar_id, start_utc, end_utc);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY, list_id TEXT NOT NULL, parent_id TEXT, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
  due TEXT, tzid TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL DEFAULT 0, flagged INTEGER NOT NULL DEFAULT 0,
  tags TEXT NOT NULL DEFAULT '[]', rrule TEXT, completed INTEGER NOT NULL DEFAULT 0, completed_at TEXT,
  section TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, alarm INTEGER,
  created TEXT NOT NULL, updated TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0, remote_href TEXT, etag TEXT
);
CREATE INDEX IF NOT EXISTS tasks_list ON tasks(list_id, completed);
-- Adjuntos: documentos (copiados y cifrados dentro de la base de datos), enlaces y carpetas (referencias).
CREATE TABLE IF NOT EXISTS attachments (
  id TEXT PRIMARY KEY, owner_kind TEXT NOT NULL, owner_id TEXT NOT NULL, kind TEXT NOT NULL,
  name TEXT NOT NULL, target TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, data BLOB, created TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS attachments_owner ON attachments(owner_id);
-- Registro de cambios ordenado: base para la futura sincronización con el servidor zero-knowledge.
-- Cuentas del servidor zero-knowledge (la clave de cuenta va aquí, dentro de la base de datos cifrada).
CREATE TABLE IF NOT EXISTS zk_accounts (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, urls TEXT NOT NULL, active_url TEXT, username TEXT NOT NULL,
  token TEXT NOT NULL, account_key BLOB NOT NULL, last_seq INTEGER NOT NULL DEFAULT 0,
  pushed_seq INTEGER NOT NULL DEFAULT 0, last_sync TEXT, last_error TEXT
);
CREATE TABLE IF NOT EXISTS changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
  op TEXT NOT NULL, at TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0
);
"#;

/// Añade columnas nuevas a bases de datos creadas con versiones anteriores.
fn migrate(conn: &Connection) -> Result<()> {
    let has = |table: &str, col: &str| -> Result<bool> {
        let mut st = conn.prepare(&format!("PRAGMA table_info({table})"))?;
        let cols = st.query_map([], |r| r.get::<_, String>(1))?.collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(cols.iter().any(|c| c == col))
    };
    if !has("accounts", "alt_urls")? {
        conn.execute_batch("ALTER TABLE accounts ADD COLUMN alt_urls TEXT NOT NULL DEFAULT '[]'")?;
    }
    if !has("tasks", "start")? {
        conn.execute_batch("ALTER TABLE tasks ADD COLUMN start TEXT")?;
    }
    if !has("accounts", "active_url")? {
        conn.execute_batch("ALTER TABLE accounts ADD COLUMN active_url TEXT")?;
    }
    Ok(())
}

pub struct Db {
    pub conn: Connection,
    /// Con `true`, los cambios no se anotan en el registro (al aplicar lo recibido del servidor ZK, para no reenviarlo).
    pub suppress_log: std::cell::Cell<bool>,
}

/// Metadatos de sincronización de un elemento remoto.
#[derive(Debug, Clone)]
pub struct RemoteMeta {
    pub id: String,
    pub href: Option<String>,
    pub etag: Option<String>,
    pub dirty: bool,
    pub deleted: bool,
    pub updated: String,
}

impl Db {
    /// Abre (o crea) la base de datos cifrada. Falla con `Error::WrongPassword` si la clave no es correcta.
    pub fn open(path: &Path, password: &str) -> Result<Db> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "key", password)?;
        conn.busy_timeout(Duration::from_secs(10))?;
        // Si la clave es incorrecta, la primera lectura falla.
        if conn
            .query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
            .is_err()
        {
            return Err(Error::WrongPassword);
        }
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.execute_batch(SCHEMA)?;
        migrate(&conn)?;
        conn.execute(
            "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', ?1)",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(Db { conn, suppress_log: std::cell::Cell::new(false) })
    }

    pub fn change_password(&self, new_password: &str) -> Result<()> {
        self.conn.pragma_update(None, "rekey", new_password)?;
        Ok(())
    }

    /// Número que cambia con cada escritura de cualquier proceso: lo usan los widgets para refrescar.
    pub fn data_version(&self) -> Result<i64> {
        let seq: i64 = self
            .conn
            .query_row("SELECT IFNULL(MAX(seq), 0) FROM changes", [], |r| r.get(0))?;
        Ok(seq)
    }

    fn log(&self, entity: &str, id: &str, op: &str) -> Result<()> {
        if self.suppress_log.get() {
            return Ok(());
        }
        self.conn.execute(
            "INSERT INTO changes(entity, entity_id, op, at) VALUES(?1, ?2, ?3, ?4)",
            params![entity, id, op, time::now_utc_string()],
        )?;
        Ok(())
    }

    pub fn pending_changes(&self) -> Result<i64> {
        let n: i64 = self.conn.query_row(
            "SELECT (SELECT count(*) FROM events WHERE dirty=1) + (SELECT count(*) FROM tasks WHERE dirty=1)",
            [],
            |r| r.get(0),
        )?;
        Ok(n)
    }

    // ---------------------------------------------------------------- cuentas

    pub fn accounts(&self) -> Result<Vec<Account>> {
        let mut st = self.conn.prepare(
            "SELECT id,name,base_url,username,password,principal_url,home_url,last_sync,last_error,alt_urls,active_url
             FROM accounts ORDER BY name",
        )?;
        let rows = st.query_map([], |r| {
            let alt: String = r.get(9)?;
            Ok(Account {
                id: r.get(0)?,
                name: r.get(1)?,
                base_url: r.get(2)?,
                alt_urls: serde_json::from_str(&alt).unwrap_or_default(),
                active_url: r.get(10)?,
                username: r.get(3)?,
                password: r.get(4)?,
                principal_url: r.get(5)?,
                home_url: r.get(6)?,
                last_sync: r.get(7)?,
                last_error: r.get(8)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn account(&self, id: &str) -> Result<Account> {
        self.accounts()?
            .into_iter()
            .find(|a| a.id == id)
            .ok_or_else(|| Error::NotFound(format!("cuenta {id}")))
    }

    pub fn save_account(&self, a: &Account) -> Result<()> {
        self.conn.execute(
            "INSERT INTO accounts(id,name,base_url,username,password,principal_url,home_url,last_sync,last_error,alt_urls,active_url)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(id) DO UPDATE SET name=?2,base_url=?3,username=?4,password=?5,principal_url=?6,
               home_url=?7,last_sync=?8,last_error=?9,alt_urls=?10,active_url=?11",
            params![
                a.id, a.name, a.base_url, a.username, a.password, a.principal_url, a.home_url, a.last_sync, a.last_error,
                serde_json::to_string(&a.alt_urls)?, a.active_url
            ],
        )?;
        Ok(())
    }

    pub fn delete_account(&self, id: &str) -> Result<()> {
        let cals: Vec<String> = self
            .calendars()?
            .into_iter()
            .filter(|c| c.account_id.as_deref() == Some(id))
            .map(|c| c.id)
            .collect();
        for c in cals {
            self.delete_calendar(&c)?;
        }
        self.conn.execute("DELETE FROM accounts WHERE id=?1", params![id])?;
        Ok(())
    }

    // ---------------------------------------------------------------- calendarios

    fn row_calendar(r: &Row) -> rusqlite::Result<Calendar> {
        Ok(Calendar {
            id: r.get(0)?,
            name: r.get(1)?,
            color: r.get(2)?,
            kind: r.get(3)?,
            source: r.get(4)?,
            visible: r.get::<_, i64>(5)? != 0,
            position: r.get(6)?,
            ics_path: r.get(7)?,
            account_id: r.get(8)?,
            remote_url: r.get(9)?,
            ctag: r.get(10)?,
            readonly: r.get::<_, i64>(11)? != 0,
        })
    }

    pub fn calendars(&self) -> Result<Vec<Calendar>> {
        let mut st = self.conn.prepare(
            "SELECT id,name,color,kind,source,visible,position,ics_path,account_id,remote_url,ctag,readonly
             FROM calendars ORDER BY position, name",
        )?;
        let rows = st.query_map([], Self::row_calendar)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn calendar(&self, id: &str) -> Result<Calendar> {
        self.conn
            .query_row(
                "SELECT id,name,color,kind,source,visible,position,ics_path,account_id,remote_url,ctag,readonly
                 FROM calendars WHERE id=?1",
                params![id],
                Self::row_calendar,
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("calendario {id}")))
    }

    pub fn save_calendar(&self, c: &mut Calendar) -> Result<()> {
        if c.id.is_empty() {
            c.id = uuid::Uuid::new_v4().to_string();
        }
        self.conn.execute(
            "INSERT INTO calendars(id,name,color,kind,source,visible,position,ics_path,account_id,remote_url,ctag,readonly)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
             ON CONFLICT(id) DO UPDATE SET name=?2,color=?3,kind=?4,source=?5,visible=?6,position=?7,ics_path=?8,
               account_id=?9,remote_url=?10,ctag=?11,readonly=?12",
            params![
                c.id, c.name, c.color, c.kind, c.source, c.visible as i64, c.position, c.ics_path,
                c.account_id, c.remote_url, c.ctag, c.readonly as i64
            ],
        )?;
        self.log("calendar", &c.id, "upsert")?;
        Ok(())
    }

    pub fn delete_calendar(&self, id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM attachments WHERE owner_id IN (SELECT id FROM events WHERE calendar_id=?1)
               OR owner_id IN (SELECT id FROM tasks WHERE list_id=?1)",
            params![id],
        )?;
        self.conn.execute("DELETE FROM events WHERE calendar_id=?1", params![id])?;
        self.conn.execute("DELETE FROM tasks WHERE list_id=?1", params![id])?;
        self.conn.execute("DELETE FROM calendars WHERE id=?1", params![id])?;
        self.log("calendar", id, "delete")?;
        Ok(())
    }

    pub fn ics_mtime(&self, id: &str) -> Result<Option<i64>> {
        Ok(self
            .conn
            .query_row("SELECT ics_mtime FROM calendars WHERE id=?1", params![id], |r| r.get(0))
            .optional()?
            .flatten())
    }

    pub fn set_ics_mtime(&self, id: &str, mtime: i64) -> Result<()> {
        self.conn
            .execute("UPDATE calendars SET ics_mtime=?2 WHERE id=?1", params![id, mtime])?;
        Ok(())
    }

    // ---------------------------------------------------------------- eventos

    const EVENT_COLS: &'static str =
        "id,calendar_id,title,notes,location,all_day,start,end,tzid,rrule,exdates,alarms,created,updated";

    fn row_event(r: &Row) -> rusqlite::Result<Event> {
        let ex: String = r.get(10)?;
        let al: String = r.get(11)?;
        Ok(Event {
            id: r.get(0)?,
            calendar_id: r.get(1)?,
            title: r.get(2)?,
            notes: r.get(3)?,
            location: r.get(4)?,
            all_day: r.get::<_, i64>(5)? != 0,
            start: r.get(6)?,
            end: r.get(7)?,
            tzid: r.get(8)?,
            rrule: r.get(9)?,
            exdates: serde_json::from_str(&ex).unwrap_or_default(),
            alarms: serde_json::from_str(&al).unwrap_or_default(),
            created: r.get(12)?,
            updated: r.get(13)?,
        })
    }

    pub fn event(&self, id: &str) -> Result<Event> {
        let sql = format!("SELECT {} FROM events WHERE id=?1 AND deleted=0", Self::EVENT_COLS);
        self.conn
            .query_row(&sql, params![id], Self::row_event)
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("evento {id}")))
    }

    /// Eventos candidatos a solaparse con [from_utc, to_utc) (los recurrentes se filtran después al expandir).
    pub fn events_candidates(&self, from_utc: i64, to_utc: i64) -> Result<Vec<Event>> {
        let sql = format!(
            "SELECT {} FROM events e WHERE deleted=0
               AND calendar_id IN (SELECT id FROM calendars WHERE visible=1)
               AND start_utc < ?2 AND (end_utc > ?1 OR rrule IS NOT NULL)",
            Self::EVENT_COLS
        );
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map(params![from_utc, to_utc], Self::row_event)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn events_in_calendar(&self, calendar_id: &str) -> Result<Vec<Event>> {
        let sql = format!(
            "SELECT {} FROM events WHERE deleted=0 AND calendar_id=?1 ORDER BY start_utc",
            Self::EVENT_COLS
        );
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map(params![calendar_id], Self::row_event)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn all_events(&self) -> Result<Vec<Event>> {
        let sql = format!("SELECT {} FROM events WHERE deleted=0", Self::EVENT_COLS);
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map([], Self::row_event)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Guarda un evento. `dirty` marca que debe subirse al servidor remoto en la próxima sincronización.
    pub fn save_event(&self, e: &mut Event, dirty: bool) -> Result<()> {
        if e.id.is_empty() {
            e.id = uuid::Uuid::new_v4().to_string();
        }
        if e.tzid.is_empty() {
            e.tzid = time::system_tzid();
        }
        let now = time::now_utc_string();
        if e.created.is_empty() {
            e.created = now.clone();
        }
        if dirty || e.updated.is_empty() {
            e.updated = now;
        }
        let s = time::parse_local(&e.start).ok_or_else(|| Error::Invalid(format!("inicio no válido: {}", e.start)))?;
        let mut en = time::parse_local(&e.end).unwrap_or(s);
        if en < s {
            en = s;
        }
        if e.all_day {
            e.start = time::fmt_date(&s);
            if en <= s {
                en = s + chrono::Duration::days(1);
            }
            e.end = time::fmt_date(&en);
        } else {
            e.start = time::fmt_local(&s);
            e.end = time::fmt_local(&en);
        }
        let su = time::to_utc(&s, &e.tzid).timestamp();
        let eu = time::to_utc(&en, &e.tzid).timestamp();
        let source = self.calendar(&e.calendar_id)?.source;
        let mark_dirty = dirty && source == SOURCE_CALDAV;
        self.conn.execute(
            "INSERT INTO events(id,calendar_id,title,notes,location,all_day,start,end,tzid,rrule,exdates,alarms,
                                start_utc,end_utc,created,updated,deleted,dirty)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,0,?17)
             ON CONFLICT(id) DO UPDATE SET calendar_id=?2,title=?3,notes=?4,location=?5,all_day=?6,start=?7,end=?8,
               tzid=?9,rrule=?10,exdates=?11,alarms=?12,start_utc=?13,end_utc=?14,updated=?16,deleted=0,
               dirty=MAX(dirty, ?17)",
            params![
                e.id, e.calendar_id, e.title, e.notes, e.location, e.all_day as i64, e.start, e.end, e.tzid,
                e.rrule.as_ref().filter(|r| !r.is_empty()), serde_json::to_string(&e.exdates)?,
                serde_json::to_string(&e.alarms)?, su, eu, e.created, e.updated, mark_dirty as i64
            ],
        )?;
        self.log("event", &e.id, "upsert")?;
        Ok(())
    }

    /// Borra un evento. En calendarios CalDAV deja una lápida hasta que el servidor confirma el borrado.
    pub fn delete_event(&self, id: &str) -> Result<()> {
        self.delete_attachments_of(id)?;
        let href: Option<String> = self
            .conn
            .query_row("SELECT remote_href FROM events WHERE id=?1", params![id], |r| r.get(0))
            .optional()?
            .flatten();
        if href.is_some() {
            self.conn.execute(
                "UPDATE events SET deleted=1, dirty=1, updated=?2 WHERE id=?1",
                params![id, time::now_utc_string()],
            )?;
        } else {
            self.conn.execute("DELETE FROM events WHERE id=?1", params![id])?;
        }
        self.log("event", id, "delete")?;
        Ok(())
    }

    pub fn purge_event(&self, id: &str) -> Result<()> {
        self.delete_attachments_of(id)?;
        self.conn.execute("DELETE FROM events WHERE id=?1", params![id])?;
        Ok(())
    }

    // ---------------------------------------------------------------- tareas

    const TASK_COLS: &'static str = "id,list_id,parent_id,title,notes,due,tzid,priority,flagged,tags,rrule,completed,
        completed_at,section,position,alarm,created,updated,start";

    fn row_task(r: &Row) -> rusqlite::Result<Task> {
        let tags: String = r.get(9)?;
        Ok(Task {
            id: r.get(0)?,
            list_id: r.get(1)?,
            parent_id: r.get(2)?,
            title: r.get(3)?,
            notes: r.get(4)?,
            due: r.get(5)?,
            tzid: r.get(6)?,
            priority: r.get(7)?,
            flagged: r.get::<_, i64>(8)? != 0,
            tags: serde_json::from_str(&tags).unwrap_or_default(),
            rrule: r.get(10)?,
            completed: r.get::<_, i64>(11)? != 0,
            completed_at: r.get(12)?,
            section: r.get(13)?,
            position: r.get(14)?,
            alarm: r.get(15)?,
            created: r.get(16)?,
            updated: r.get(17)?,
            start: r.get(18)?,
        })
    }

    pub fn task(&self, id: &str) -> Result<Task> {
        let sql = format!("SELECT {} FROM tasks WHERE id=?1 AND deleted=0", Self::TASK_COLS);
        self.conn
            .query_row(&sql, params![id], Self::row_task)
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("tarea {id}")))
    }

    pub fn tasks_where(&self, clause: &str, p: &[&dyn rusqlite::ToSql]) -> Result<Vec<Task>> {
        let sql = format!(
            "SELECT {} FROM tasks WHERE deleted=0 AND list_id IN (SELECT id FROM calendars) AND ({clause})
             ORDER BY completed, position, IFNULL(due, '9999'), created",
            Self::TASK_COLS
        );
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map(p, Self::row_task)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn children(&self, parent_id: &str) -> Result<Vec<Task>> {
        self.tasks_where("parent_id = ?1", &[&parent_id])
    }

    pub fn save_task(&self, t: &mut Task, dirty: bool) -> Result<()> {
        if t.id.is_empty() {
            t.id = uuid::Uuid::new_v4().to_string();
        }
        if t.tzid.is_empty() {
            t.tzid = time::system_tzid();
        }
        let now = time::now_utc_string();
        if t.created.is_empty() {
            t.created = now.clone();
        }
        if dirty || t.updated.is_empty() {
            t.updated = now;
        }
        if let Some(d) = &t.due {
            if d.trim().is_empty() {
                t.due = None;
            } else {
                let p = time::parse_local(d).ok_or_else(|| Error::Invalid(format!("fecha no válida: {d}")))?;
                t.due = Some(if d.contains('T') { time::fmt_local(&p) } else { time::fmt_date(&p) });
            }
        }
        if let Some(d) = &t.start {
            if d.trim().is_empty() {
                t.start = None;
            } else {
                let p = time::parse_local(d).ok_or_else(|| Error::Invalid(format!("fecha de inicio no válida: {d}")))?;
                t.start = Some(if d.contains('T') { time::fmt_local(&p) } else { time::fmt_date(&p) });
            }
        }
        if let (Some(s), Some(d)) = (&t.start, &t.due) {
            if time::parse_local(s) > time::parse_local(d) {
                return Err(Error::Invalid("la fecha de inicio es posterior a la de fin".into()));
            }
        }
        if let Some(p) = &t.parent_id {
            if p.is_empty() || p == &t.id {
                t.parent_id = None;
            }
        }
        let mut tags: Vec<String> = t
            .tags
            .iter()
            .map(|s| normalize_tag(s))
            .filter(|s| s.len() > 1)
            .collect();
        tags.sort();
        tags.dedup();
        t.tags = tags;
        t.priority = t.priority.clamp(0, 3);
        let source = self.calendar(&t.list_id)?.source;
        let mark_dirty = dirty && source == SOURCE_CALDAV;
        self.conn.execute(
            "INSERT INTO tasks(id,list_id,parent_id,title,notes,due,tzid,priority,flagged,tags,rrule,completed,completed_at,
                               section,position,alarm,created,updated,deleted,dirty,start)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,0,?19,?20)
             ON CONFLICT(id) DO UPDATE SET list_id=?2,parent_id=?3,title=?4,notes=?5,due=?6,tzid=?7,priority=?8,flagged=?9,
               tags=?10,rrule=?11,completed=?12,completed_at=?13,section=?14,position=?15,alarm=?16,updated=?18,deleted=0,
               dirty=MAX(dirty, ?19),start=?20",
            params![
                t.id, t.list_id, t.parent_id, t.title, t.notes, t.due, t.tzid, t.priority, t.flagged as i64,
                serde_json::to_string(&t.tags)?, t.rrule.as_ref().filter(|r| !r.is_empty()), t.completed as i64,
                t.completed_at, t.section, t.position, t.alarm, t.created, t.updated, mark_dirty as i64, t.start
            ],
        )?;
        self.log("task", &t.id, "upsert")?;
        Ok(())
    }

    /// Borra una tarea y sus subtareas.
    pub fn delete_task(&self, id: &str) -> Result<()> {
        for c in self.children(id)? {
            self.delete_task(&c.id)?;
        }
        self.delete_attachments_of(id)?;
        let href: Option<String> = self
            .conn
            .query_row("SELECT remote_href FROM tasks WHERE id=?1", params![id], |r| r.get(0))
            .optional()?
            .flatten();
        if href.is_some() {
            self.conn.execute(
                "UPDATE tasks SET deleted=1, dirty=1, updated=?2 WHERE id=?1",
                params![id, time::now_utc_string()],
            )?;
        } else {
            self.conn.execute("DELETE FROM tasks WHERE id=?1", params![id])?;
        }
        self.log("task", id, "delete")?;
        Ok(())
    }

    pub fn purge_task(&self, id: &str) -> Result<()> {
        self.delete_attachments_of(id)?;
        self.conn.execute("DELETE FROM tasks WHERE id=?1", params![id])?;
        Ok(())
    }

    pub fn tags(&self) -> Result<Vec<(String, i64)>> {
        let mut st = self.conn.prepare(
            "SELECT j.value, count(*) FROM tasks, json_each(tasks.tags) j
             WHERE deleted=0 AND completed=0 GROUP BY j.value ORDER BY j.value",
        )?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    // ---------------------------------------------------------------- sincronización remota

    pub fn remote_meta(&self, table: &str, cal_id: &str) -> Result<Vec<RemoteMeta>> {
        let col = if table == "events" { "calendar_id" } else { "list_id" };
        let sql = format!("SELECT id, remote_href, etag, dirty, deleted, updated FROM {table} WHERE {col}=?1");
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map(params![cal_id], |r| {
            Ok(RemoteMeta {
                id: r.get(0)?,
                href: r.get(1)?,
                etag: r.get(2)?,
                dirty: r.get::<_, i64>(3)? != 0,
                deleted: r.get::<_, i64>(4)? != 0,
                updated: r.get(5)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn set_remote(&self, table: &str, id: &str, href: &str, etag: Option<&str>) -> Result<()> {
        let sql = format!("UPDATE {table} SET remote_href=?2, etag=?3, dirty=0 WHERE id=?1");
        self.conn.execute(&sql, params![id, href, etag])?;
        Ok(())
    }

    // ---------------------------------------------------------------- adjuntos

    pub fn attachments(&self, owner_id: &str) -> Result<Vec<Attachment>> {
        let mut st = self.conn.prepare(
            "SELECT id, owner_kind, owner_id, kind, name, target, size, created FROM attachments WHERE owner_id=?1 ORDER BY created",
        )?;
        let rows = st.query_map(params![owner_id], Self::row_attachment)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn row_attachment(r: &Row) -> rusqlite::Result<Attachment> {
        Ok(Attachment {
            id: r.get(0)?,
            owner_kind: r.get(1)?,
            owner_id: r.get(2)?,
            kind: r.get(3)?,
            name: r.get(4)?,
            target: r.get(5)?,
            size: r.get(6)?,
            created: r.get(7)?,
        })
    }

    pub fn attachment(&self, id: &str) -> Result<(Attachment, Option<Vec<u8>>)> {
        self.conn
            .query_row(
                "SELECT id, owner_kind, owner_id, kind, name, target, size, created, data FROM attachments WHERE id=?1",
                params![id],
                |r| Ok((Self::row_attachment(r)?, r.get::<_, Option<Vec<u8>>>(8)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("adjunto {id}")))
    }

    pub fn save_attachment(&self, a: &Attachment, data: Option<&[u8]>) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO attachments(id, owner_kind, owner_id, kind, name, target, size, data, created)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![a.id, a.owner_kind, a.owner_id, a.kind, a.name, a.target, a.size, data, a.created],
        )?;
        self.log("attachment", &a.id, "upsert")?;
        Ok(())
    }

    pub fn delete_attachment(&self, id: &str) -> Result<()> {
        self.conn.execute("DELETE FROM attachments WHERE id=?1", params![id])?;
        self.log("attachment", id, "delete")?;
        Ok(())
    }

    pub fn delete_attachments_of(&self, owner_id: &str) -> Result<()> {
        self.conn.execute("DELETE FROM attachments WHERE owner_id=?1", params![owner_id])?;
        Ok(())
    }

    pub fn attachment_count(&self, owner_id: &str) -> Result<i64> {
        Ok(self.conn.query_row("SELECT count(*) FROM attachments WHERE owner_id=?1", params![owner_id], |r| r.get(0))?)
    }

    /// Todos los adjuntos con su contenido (para las copias de seguridad).
    pub fn all_attachments(&self) -> Result<Vec<(Attachment, Option<Vec<u8>>)>> {
        let mut st = self.conn.prepare("SELECT id, owner_kind, owner_id, kind, name, target, size, created, data FROM attachments")?;
        let rows = st.query_map([], |r| Ok((Self::row_attachment(r)?, r.get::<_, Option<Vec<u8>>>(8)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    // ---------------------------------------------------------------- búsqueda

    pub fn search(&self, q: &str) -> Result<(Vec<Event>, Vec<Task>)> {
        let like = format!("%{}%", q.replace('%', "\\%").replace('_', "\\_"));
        let sql = format!(
            "SELECT {} FROM events WHERE deleted=0 AND (title LIKE ?1 ESCAPE '\\' OR notes LIKE ?1 ESCAPE '\\'
               OR location LIKE ?1 ESCAPE '\\') ORDER BY start_utc DESC LIMIT 100",
            Self::EVENT_COLS
        );
        let mut st = self.conn.prepare(&sql)?;
        let ev = st
            .query_map(params![like], Self::row_event)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let tasks = self.tasks_where(
            "title LIKE ?1 ESCAPE '\\' OR notes LIKE ?1 ESCAPE '\\' OR tags LIKE ?1 ESCAPE '\\'",
            &[&like],
        )?;
        Ok((ev, tasks))
    }

    pub fn all_tasks(&self) -> Result<Vec<Task>> {
        self.tasks_where("1=1", &[])
    }

    pub fn transaction<T>(&mut self, f: impl FnOnce(&Db) -> Result<T>) -> Result<T> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        match f(self) {
            Ok(v) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
}

pub fn normalize_tag(s: &str) -> String {
    let t = s.trim().trim_start_matches('#').to_lowercase();
    if t.is_empty() {
        String::new()
    } else {
        format!("#{t}")
    }
}
