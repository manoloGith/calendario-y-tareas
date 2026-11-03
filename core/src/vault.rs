//! La «bóveda»: base de datos cifrada abierta + reglas de negocio (recurrencias, listas inteligentes,
//! archivos .ics enlazados, cuentas CalDAV y avisos).
use crate::caldav::{self, Dav, SyncStats};
use crate::db::Db;
use crate::error::{Error, Result};
use crate::ics;
use crate::model::*;
use crate::nlp;
use crate::recur;
use crate::time;
use chrono::{Duration, NaiveDateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub struct Vault {
    pub db: Db,
    pub path: PathBuf,
    password: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TaskNode {
    #[serde(flatten)]
    pub task: Task,
    pub children: Vec<Task>,
    pub sub_total: usize,
    pub sub_done: usize,
    pub list_name: String,
    pub list_color: String,
    pub overdue: bool,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    pub today: i64,
    pub scheduled: i64,
    pub all: i64,
    pub flagged: i64,
    pub completed: i64,
    pub lists: Vec<(String, i64)>,
    pub tags: Vec<(String, i64)>,
}

#[derive(Deserialize, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct TaskFilter {
    pub list_id: Option<String>,
    /// "today", "scheduled", "all", "flagged", "completed"
    pub smart: Option<String>,
    pub tag: Option<String>,
    #[serde(default)]
    pub include_completed: bool,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Alarm {
    pub kind: String,
    pub id: String,
    pub title: String,
    pub at: String,
    pub starts: String,
}

impl Vault {
    pub fn create(path: &Path, password: &str) -> Result<Vault> {
        if path.exists() {
            return Err(Error::Invalid("ya existe una bóveda en esa ruta".into()));
        }
        if password.chars().count() < 8 {
            return Err(Error::Invalid("la contraseña debe tener al menos 8 caracteres".into()));
        }
        let v = Vault { db: Db::open(path, password)?, path: path.to_path_buf(), password: password.to_string() };
        let defaults = [("Personal", "#FF9500", 0), ("Trabajo", "#007AFF", 1)];
        for (name, color, pos) in defaults {
            let mut c = Calendar {
                id: String::new(),
                name: name.into(),
                color: color.into(),
                kind: "both".into(),
                source: SOURCE_LOCAL.into(),
                visible: true,
                position: pos,
                ics_path: None,
                account_id: None,
                remote_url: None,
                ctag: None,
                readonly: false,
            };
            v.db.save_calendar(&mut c)?;
        }
        Ok(v)
    }

    pub fn open(path: &Path, password: &str) -> Result<Vault> {
        if !path.exists() {
            return Err(Error::NotFound("no hay ninguna bóveda en esa ruta".into()));
        }
        Ok(Vault { db: Db::open(path, password)?, path: path.to_path_buf(), password: password.to_string() })
    }

    /// Credenciales para abrir conexiones adicionales (sincronización en segundo plano).
    pub fn credentials(&self) -> (PathBuf, String) {
        (self.path.clone(), self.password.clone())
    }

    pub fn change_password(&mut self, old: &str, new: &str) -> Result<()> {
        if old != self.password {
            return Err(Error::WrongPassword);
        }
        if new.chars().count() < 8 {
            return Err(Error::Invalid("la contraseña debe tener al menos 8 caracteres".into()));
        }
        self.db.change_password(new)?;
        self.password = new.to_string();
        Ok(())
    }

    fn view_tz(&self) -> String {
        time::system_tzid()
    }

    fn writable(&self, cal_id: &str) -> Result<Calendar> {
        let c = self.db.calendar(cal_id)?;
        if c.readonly {
            return Err(Error::Invalid(format!("«{}» es de solo lectura", c.name)));
        }
        Ok(c)
    }

    /// Tras cambiar un calendario enlazado a un .ics, se reescribe el archivo.
    fn after_change(&self, cal_id: &str) -> Result<()> {
        let c = self.db.calendar(cal_id)?;
        if c.source == SOURCE_ICS {
            if let Some(p) = &c.ics_path {
                self.write_ics(&c, Path::new(p))?;
                if let Ok(m) = std::fs::metadata(p).and_then(|m| m.modified()) {
                    let secs = m.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
                    self.db.set_ics_mtime(&c.id, secs)?;
                }
            }
        }
        Ok(())
    }

    // ---------------------------------------------------------------- eventos

    pub fn range(&self, from: &str, to: &str) -> Result<Vec<Occurrence>> {
        let tz = self.view_tz();
        let f = time::parse_local(from).ok_or_else(|| Error::Invalid(format!("fecha no válida: {from}")))?;
        let t = time::parse_local(to).ok_or_else(|| Error::Invalid(format!("fecha no válida: {to}")))?;
        let fu = time::to_utc(&f, &tz);
        let tu = time::to_utc(&t, &tz);
        // Margen de un día para los eventos de día completo (son flotantes).
        let cands = self.db.events_candidates((fu - Duration::days(1)).timestamp(), (tu + Duration::days(1)).timestamp())?;
        let colors: std::collections::HashMap<String, String> =
            self.db.calendars()?.into_iter().map(|c| (c.id, c.color)).collect();
        let mut out = vec![];
        for e in cands {
            let color = colors.get(&e.calendar_id).cloned().unwrap_or_default();
            if e.all_day {
                let fu2 = chrono::TimeZone::from_utc_datetime(&Utc, &f);
                let tu2 = chrono::TimeZone::from_utc_datetime(&Utc, &t);
                out.extend(recur::occurrences(&e, &color, fu2, tu2, &tz));
            } else {
                out.extend(recur::occurrences(&e, &color, fu, tu, &tz));
            }
        }
        out.sort_by(|a, b| (!a.all_day, &a.start, &a.title).cmp(&(!b.all_day, &b.start, &b.title)));
        Ok(out)
    }

    fn check_event(&self, e: &Event) -> Result<()> {
        if e.title.trim().is_empty() {
            return Err(Error::Invalid("el evento necesita un título".into()));
        }
        if let Some(r) = e.rrule.as_deref().filter(|r| !r.trim().is_empty()) {
            if !recur::validate(r) {
                return Err(Error::Invalid(format!("regla de repetición no válida: {r}")));
            }
        }
        Ok(())
    }

    /// Guarda un evento. Para editar una sola ocurrencia (`scope = "this"`) o desde una en adelante (`"future"`)
    /// se indica `occurrence` (inicio original en la zona del evento).
    pub fn save_event(&self, mut e: Event, scope: &str, occurrence: Option<&str>) -> Result<Event> {
        self.check_event(&e)?;
        self.writable(&e.calendar_id)?;
        let existing = if e.id.is_empty() { None } else { self.db.event(&e.id).ok() };
        if let (Some(master), Some(occ)) = (existing.clone(), occurrence) {
            let recurring = master.rrule.as_deref().map(|r| !r.is_empty()).unwrap_or(false);
            if recurring && scope == "this" {
                let mut m = master.clone();
                m.exdates.push(occ.to_string());
                self.db.save_event(&mut m, true)?;
                e.id = String::new();
                e.rrule = None;
                e.exdates.clear();
                e.created = String::new();
                self.db.save_event(&mut e, true)?;
                self.after_change(&e.calendar_id)?;
                if m.calendar_id != e.calendar_id {
                    self.after_change(&m.calendar_id)?;
                }
                return Ok(e);
            }
            if recurring && scope == "future" && occ != master.start {
                let mut m = master.clone();
                m.rrule = Some(with_until(master.rrule.as_deref().unwrap_or(""), occ, &master.tzid, master.all_day));
                self.db.save_event(&mut m, true)?;
                e.id = String::new();
                e.created = String::new();
                e.rrule = e.rrule.map(|r| strip_count_until(&r));
                self.db.save_event(&mut e, true)?;
                self.after_change(&e.calendar_id)?;
                return Ok(e);
            }
        }
        if let Some(old) = &existing {
            if old.calendar_id != e.calendar_id {
                // Cambio de calendario: se borra del origen y se crea en el destino.
                self.db.delete_event(&old.id)?;
                self.after_change(&old.calendar_id)?;
                if self.db.calendar(&old.calendar_id)?.source == SOURCE_CALDAV {
                    e.id = String::new();
                }
            }
        }
        self.db.save_event(&mut e, true)?;
        self.after_change(&e.calendar_id)?;
        Ok(e)
    }

    pub fn delete_event(&self, id: &str, scope: &str, occurrence: Option<&str>) -> Result<()> {
        let e = self.db.event(id)?;
        self.writable(&e.calendar_id)?;
        let recurring = e.rrule.as_deref().map(|r| !r.is_empty()).unwrap_or(false);
        match (recurring, scope, occurrence) {
            (true, "this", Some(occ)) => {
                let mut m = e.clone();
                m.exdates.push(occ.to_string());
                self.db.save_event(&mut m, true)?;
            }
            (true, "future", Some(occ)) if occ != e.start => {
                let mut m = e.clone();
                m.rrule = Some(with_until(e.rrule.as_deref().unwrap_or(""), occ, &e.tzid, e.all_day));
                self.db.save_event(&mut m, true)?;
            }
            _ => self.db.delete_event(id)?,
        }
        self.after_change(&e.calendar_id)
    }

    // ---------------------------------------------------------------- tareas

    fn node(&self, t: Task, cals: &[Calendar], today: &str) -> Result<TaskNode> {
        let children = self.db.children(&t.id)?;
        let done = children.iter().filter(|c| c.completed).count();
        let cal = cals.iter().find(|c| c.id == t.list_id);
        let overdue = !t.completed
            && t.due.as_deref().map(|d| {
                if d.contains('T') { d < time::fmt_local(&time::now_local(&t.tzid)).as_str() } else { d < today }
            }).unwrap_or(false);
        Ok(TaskNode {
            sub_total: children.len(),
            sub_done: done,
            children,
            list_name: cal.map(|c| c.name.clone()).unwrap_or_default(),
            list_color: cal.map(|c| c.color.clone()).unwrap_or_default(),
            overdue,
            task: t,
        })
    }

    pub fn tasks(&self, f: &TaskFilter) -> Result<Vec<TaskNode>> {
        let today = time::fmt_date(&time::now_local(&self.view_tz()));
        let tomorrow = time::fmt_date(&(time::now_local(&self.view_tz()) + Duration::days(1)));
        let done = if f.include_completed { "1=1" } else { "completed=0" };
        let list = match (&f.list_id, f.smart.as_deref(), &f.tag) {
            (Some(l), _, _) => self.db.tasks_where(&format!("parent_id IS NULL AND list_id=?1 AND {done}"), &[l])?,
            (_, Some("today"), _) => self.db.tasks_where("completed=0 AND due IS NOT NULL AND due < ?1", &[&tomorrow])?,
            (_, Some("scheduled"), _) => self.db.tasks_where("completed=0 AND due IS NOT NULL", &[])?,
            (_, Some("flagged"), _) => self.db.tasks_where("completed=0 AND flagged=1", &[])?,
            (_, Some("completed"), _) => self.db.tasks_where("completed=1 AND parent_id IS NULL", &[])?,
            (_, _, Some(tag)) => {
                let like = format!("%\"{}\"%", crate::db::normalize_tag(tag));
                self.db.tasks_where(&format!("tags LIKE ?1 AND {done}"), &[&like])?
            }
            _ => self.db.tasks_where(&format!("parent_id IS NULL AND {done}"), &[])?,
        };
        let cals = self.db.calendars()?;
        let mut out: Vec<TaskNode> = list.into_iter().map(|t| self.node(t, &cals, &today)).collect::<Result<_>>()?;
        if matches!(f.smart.as_deref(), Some("today") | Some("scheduled")) {
            out.sort_by(|a, b| a.task.due.cmp(&b.task.due));
        }
        if f.smart.as_deref() == Some("completed") {
            out.sort_by(|a, b| b.task.completed_at.cmp(&a.task.completed_at));
        }
        Ok(out)
    }

    /// Tareas con vencimiento en [from, to) para mostrarlas en el calendario.
    pub fn tasks_in_range(&self, from: &str, to: &str) -> Result<Vec<TaskNode>> {
        let cals: Vec<Calendar> = self.db.calendars()?;
        let visible: Vec<String> = cals.iter().filter(|c| c.visible).map(|c| c.id.clone()).collect();
        let today = time::fmt_date(&time::now_local(&self.view_tz()));
        let list = self.db.tasks_where("due IS NOT NULL AND due >= ?1 AND due < ?2", &[&from, &to])?;
        list.into_iter()
            .filter(|t| visible.contains(&t.list_id))
            .map(|t| self.node(t, &cals, &today))
            .collect()
    }

    pub fn counts(&self) -> Result<Counts> {
        let q = |sql: &str, p: &[&dyn rusqlite::ToSql]| -> Result<i64> {
            Ok(self.db.conn.query_row(
                &format!("SELECT count(*) FROM tasks WHERE deleted=0 AND list_id IN (SELECT id FROM calendars) AND {sql}"),
                p,
                |r| r.get(0),
            )?)
        };
        let tomorrow = time::fmt_date(&(time::now_local(&self.view_tz()) + Duration::days(1)));
        let mut st = self.db.conn.prepare(
            "SELECT list_id, count(*) FROM tasks WHERE deleted=0 AND completed=0 AND parent_id IS NULL GROUP BY list_id",
        )?;
        let lists = st
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(Counts {
            today: q("completed=0 AND due IS NOT NULL AND due < ?1", &[&tomorrow])?,
            scheduled: q("completed=0 AND due IS NOT NULL", &[])?,
            all: q("completed=0 AND parent_id IS NULL", &[])?,
            flagged: q("completed=0 AND flagged=1", &[])?,
            completed: q("completed=1 AND parent_id IS NULL", &[])?,
            lists,
            tags: self.db.tags()?,
        })
    }

    pub fn save_task(&self, mut t: Task) -> Result<Task> {
        if t.title.trim().is_empty() {
            return Err(Error::Invalid("la tarea necesita un título".into()));
        }
        if let Some(r) = t.rrule.as_deref().filter(|r| !r.trim().is_empty()) {
            if !recur::validate(r) {
                return Err(Error::Invalid(format!("regla de repetición no válida: {r}")));
            }
            if t.due.is_none() {
                return Err(Error::Invalid("una tarea recurrente necesita fecha".into()));
            }
        }
        self.writable(&t.list_id)?;
        let old = if t.id.is_empty() { None } else { self.db.task(&t.id).ok() };
        if let Some(pid) = &t.parent_id {
            let parent = self.db.task(pid)?;
            if parent.parent_id.is_some() {
                return Err(Error::Invalid("solo se admite un nivel de subtareas".into()));
            }
            t.list_id = parent.list_id;
        }
        if t.completed && t.completed_at.is_none() {
            t.completed_at = Some(time::now_utc_string());
        }
        if !t.completed {
            t.completed_at = None;
        }
        if t.id.is_empty() && t.position == 0 {
            t.position = self
                .db
                .conn
                .query_row("SELECT IFNULL(MAX(position), 0) + 1 FROM tasks WHERE list_id=?1", [&t.list_id], |r| r.get(0))?;
        }
        self.db.save_task(&mut t, true)?;
        // Si la tarea madre cambia de lista, sus subtareas la acompañan.
        if let Some(o) = &old {
            if o.list_id != t.list_id {
                for mut c in self.db.children(&t.id)? {
                    c.list_id = t.list_id.clone();
                    self.db.save_task(&mut c, true)?;
                }
                self.after_change(&o.list_id)?;
            }
        }
        self.after_change(&t.list_id)?;
        Ok(t)
    }

    /// Completa o reabre una tarea. Una tarea recurrente pasa a su siguiente fecha (como Recordatorios).
    pub fn toggle_task(&self, id: &str) -> Result<Task> {
        let mut t = self.db.task(id)?;
        self.writable(&t.list_id)?;
        if !t.completed {
            if let (Some(rule), Some(due)) = (t.rrule.clone().filter(|r| !r.is_empty()), t.due.clone()) {
                let d = time::parse_local(&due).unwrap();
                let from = time::now_local(&t.tzid).max(d);
                if let Some(next) = recur::next_after(&d, &t.tzid, &rule, &from) {
                    t.due = Some(if due.contains('T') { time::fmt_local(&next) } else { time::fmt_date(&next) });
                    self.db.save_task(&mut t, true)?;
                    for mut c in self.db.children(&t.id)? {
                        c.completed = false;
                        c.completed_at = None;
                        self.db.save_task(&mut c, true)?;
                    }
                    self.after_change(&t.list_id)?;
                    return Ok(t);
                }
            }
            t.completed = true;
            t.completed_at = Some(time::now_utc_string());
            for mut c in self.db.children(&t.id)?.into_iter().filter(|c| !c.completed) {
                c.completed = true;
                c.completed_at = t.completed_at.clone();
                self.db.save_task(&mut c, true)?;
            }
        } else {
            t.completed = false;
            t.completed_at = None;
            if let Some(pid) = &t.parent_id {
                let mut p = self.db.task(pid)?;
                if p.completed {
                    p.completed = false;
                    p.completed_at = None;
                    self.db.save_task(&mut p, true)?;
                }
            }
        }
        self.db.save_task(&mut t, true)?;
        self.after_change(&t.list_id)?;
        Ok(t)
    }

    pub fn delete_task(&self, id: &str) -> Result<()> {
        let t = self.db.task(id)?;
        self.writable(&t.list_id)?;
        self.db.delete_task(id)?;
        self.after_change(&t.list_id)
    }

    /// Crea una tarea desde texto libre («Pagar IBI mañana #casa !!»).
    pub fn quick_task(&self, text: &str, list_id: &str, parent_id: Option<String>) -> Result<Task> {
        let tz = self.view_tz();
        let mut q = nlp::parse(text, time::now_local(&tz));
        if q.rrule.is_some() && q.date.is_none() {
            // «Regar las plantas cada semana»: empieza hoy.
            q.date = Some(time::fmt_date(&time::now_local(&tz)));
        }
        self.save_task(Task {
            list_id: list_id.into(),
            parent_id,
            title: q.title,
            due: q.date,
            tzid: tz,
            priority: q.priority,
            tags: q.tags,
            rrule: q.rrule,
            ..Default::default()
        })
    }

    /// Crea un evento desde texto libre («Cena con Ana el viernes a las 21h»).
    pub fn quick_event(&self, text: &str, calendar_id: &str) -> Result<Event> {
        let tz = self.view_tz();
        let now = time::now_local(&tz);
        let q = nlp::parse(text, now);
        let (start, all_day) = match &q.date {
            Some(d) if q.has_time => (time::parse_local(d).unwrap(), false),
            Some(d) => (time::parse_local(d).unwrap(), true),
            None => {
                // Sin fecha: la próxima hora en punto.
                let next = now + Duration::hours(1);
                (next.date().and_hms_opt(chrono::Timelike::hour(&next), 0, 0).unwrap(), false)
            }
        };
        let end = if all_day { start + Duration::days(1) } else { start + Duration::minutes(q.duration_min) };
        let fmt = |d: &NaiveDateTime| if all_day { time::fmt_date(d) } else { time::fmt_local(d) };
        self.save_event(
            Event {
                calendar_id: calendar_id.into(),
                title: q.title,
                all_day,
                start: fmt(&start),
                end: fmt(&end),
                tzid: tz,
                rrule: q.rrule,
                alarms: if all_day { vec![] } else { vec![10] },
                ..Default::default()
            },
            "all",
            None,
        )
    }

    // ---------------------------------------------------------------- avisos

    pub fn alarms_between(&self, from: &str, to: &str) -> Result<Vec<Alarm>> {
        let tz = self.view_tz();
        let f = time::parse_local(from).ok_or_else(|| Error::Invalid("fecha".into()))?;
        let t = time::parse_local(to).ok_or_else(|| Error::Invalid("fecha".into()))?;
        let mut out = vec![];
        // Avisos de eventos: ocurrencias que empiezan hasta 1 día después del rango.
        let start_to = time::fmt_local(&(t + Duration::days(1)));
        for o in self.range(from, &start_to)? {
            if o.all_day {
                continue;
            }
            let Ok(e) = self.db.event(&o.event_id) else { continue };
            let s = time::parse_local(&o.start).unwrap();
            for m in &e.alarms {
                let at = s - Duration::minutes(*m);
                if at >= f && at < t {
                    out.push(Alarm { kind: "event".into(), id: o.event_id.clone(), title: o.title.clone(), at: time::fmt_local(&at), starts: o.start.clone() });
                }
            }
        }
        for task in self.db.tasks_where("completed=0 AND due IS NOT NULL AND alarm IS NOT NULL", &[])? {
            if !task.due_has_time() {
                continue;
            }
            let d = time::parse_local(task.due.as_deref().unwrap()).unwrap();
            let du = time::utc_to_local(&time::to_utc(&d, &task.tzid), &tz);
            let at = du - Duration::minutes(task.alarm.unwrap_or(0));
            if at >= f && at < t {
                out.push(Alarm { kind: "task".into(), id: task.id.clone(), title: task.title.clone(), at: time::fmt_local(&at), starts: time::fmt_local(&du) });
            }
        }
        out.sort_by(|a, b| a.at.cmp(&b.at));
        Ok(out)
    }

    // ---------------------------------------------------------------- .ics

    fn write_ics(&self, c: &Calendar, path: &Path) -> Result<()> {
        let events = self.db.events_in_calendar(&c.id)?;
        let tasks = self.db.tasks_where("list_id=?1", &[&c.id])?;
        let doc = ics::calendar_doc(&c.name, &c.color, &events, &tasks);
        let tmp = path.with_extension("ics.tmp");
        std::fs::write(&tmp, doc)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn export_ics(&self, calendar_id: &str, path: &Path) -> Result<usize> {
        let c = self.db.calendar(calendar_id)?;
        self.write_ics(&c, path)?;
        Ok(self.db.events_in_calendar(&c.id)?.len() + self.db.tasks_where("list_id=?1", &[&c.id])?.len())
    }

    fn import_into(&mut self, cal: &Calendar, parsed: ics::Parsed, replace: bool) -> Result<usize> {
        let cid = cal.id.clone();
        self.db.transaction(|db| {
            if replace {
                db.conn.execute("DELETE FROM events WHERE calendar_id=?1", [&cid])?;
                db.conn.execute("DELETE FROM tasks WHERE list_id=?1", [&cid])?;
            }
            let mut n = 0;
            for mut e in parsed.events {
                e.calendar_id = cid.clone();
                // Evita choques de UID con otros calendarios.
                if let Ok(other) = db.event(&e.id) {
                    if other.calendar_id != cid {
                        e.id = format!("{}:{}", &cid[..8.min(cid.len())], e.id);
                    }
                }
                db.save_event(&mut e, false)?;
                n += 1;
            }
            let (roots, subs): (Vec<Task>, Vec<Task>) = parsed.tasks.into_iter().partition(|t| t.parent_id.is_none());
            for mut t in roots.into_iter().chain(subs) {
                t.list_id = cid.clone();
                if let Ok(other) = db.task(&t.id) {
                    if other.list_id != cid {
                        t.id = format!("{}:{}", &cid[..8.min(cid.len())], t.id);
                    }
                }
                db.save_task(&mut t, false)?;
                n += 1;
            }
            Ok(n)
        })
    }

    /// Importa un .ics a un calendario existente o a uno nuevo (copia: el archivo no queda enlazado).
    pub fn import_ics(&mut self, path: &Path, calendar_id: Option<&str>) -> Result<(Calendar, usize)> {
        let txt = std::fs::read_to_string(path)?;
        let parsed = ics::read(&txt, &self.view_tz());
        if parsed.events.is_empty() && parsed.tasks.is_empty() {
            return Err(Error::Invalid("el archivo no contiene eventos ni tareas".into()));
        }
        let cal = match calendar_id {
            Some(id) => self.writable(id)?,
            None => {
                let mut c = new_calendar(
                    parsed.name.clone().unwrap_or_else(|| file_stem(path)),
                    parsed.color.clone().unwrap_or("#AF52DE".into()),
                    SOURCE_LOCAL,
                );
                c.position = self.db.calendars()?.len() as i64;
                self.db.save_calendar(&mut c)?;
                c
            }
        };
        let n = self.import_into(&cal, parsed, false)?;
        self.after_change(&cal.id)?;
        Ok((cal, n))
    }

    /// Enlaza un archivo .ics: el calendario refleja el archivo y los cambios se escriben en él.
    pub fn link_ics(&mut self, path: &Path, readonly: bool) -> Result<(Calendar, usize)> {
        let txt = if path.exists() { std::fs::read_to_string(path)? } else { String::new() };
        let parsed = ics::read(&txt, &self.view_tz());
        let mut c = new_calendar(
            parsed.name.clone().unwrap_or_else(|| file_stem(path)),
            parsed.color.clone().unwrap_or("#5E7FA8".into()),
            SOURCE_ICS,
        );
        c.ics_path = Some(path.display().to_string());
        c.readonly = readonly;
        c.position = self.db.calendars()?.len() as i64;
        self.db.save_calendar(&mut c)?;
        let n = self.import_into(&c, parsed, true)?;
        if !path.exists() {
            self.write_ics(&c, path)?;
        }
        self.after_change(&c.id)?;
        Ok((c, n))
    }

    /// Vuelve a leer los .ics enlazados que han cambiado en disco (otro programa los editó).
    pub fn refresh_ics(&mut self) -> Result<usize> {
        let mut changed = 0;
        for c in self.db.calendars()?.into_iter().filter(|c| c.source == SOURCE_ICS) {
            let Some(p) = c.ics_path.clone() else { continue };
            let Ok(meta) = std::fs::metadata(&p) else { continue };
            let secs = meta.modified()?.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
            if self.db.ics_mtime(&c.id)? == Some(secs) {
                continue;
            }
            let txt = std::fs::read_to_string(&p)?;
            let parsed = ics::read(&txt, &self.view_tz());
            self.import_into(&c, parsed, true)?;
            self.db.set_ics_mtime(&c.id, secs)?;
            changed += 1;
        }
        Ok(changed)
    }

    // ---------------------------------------------------------------- CalDAV

    pub fn add_caldav(&self, name: &str, url: &str, user: &str, pass: &str) -> Result<(Account, Vec<Calendar>)> {
        let dav = Dav::new(user, pass)?;
        let (principal, home, remotes) = caldav::discover(&dav, url)?;
        let acc = Account {
            id: uuid::Uuid::new_v4().to_string(),
            name: if name.trim().is_empty() { host_of(url) } else { name.trim().to_string() },
            base_url: url.trim().to_string(),
            username: user.to_string(),
            password: pass.to_string(),
            principal_url: Some(principal),
            home_url: Some(home),
            last_sync: None,
            last_error: None,
        };
        self.db.save_account(&acc)?;
        let mut cals = vec![];
        let base_pos = self.db.calendars()?.len() as i64;
        for (i, r) in remotes.into_iter().enumerate() {
            let mut c = new_calendar(r.name, r.color.unwrap_or_else(|| palette(i)), SOURCE_CALDAV);
            c.kind = r.kind;
            c.account_id = Some(acc.id.clone());
            c.remote_url = Some(r.url);
            c.position = base_pos + i as i64;
            self.db.save_calendar(&mut c)?;
            cals.push(c);
        }
        Ok((acc, cals))
    }

    pub fn create_remote_calendar(&self, account_id: &str, name: &str, color: &str, kind: &str) -> Result<Calendar> {
        let acc = self.db.account(account_id)?;
        let dav = Dav::new(&acc.username, &acc.password)?;
        let home = acc.home_url.clone().ok_or_else(|| Error::CalDav("cuenta sin calendar-home-set".into()))?;
        let url = caldav::make_calendar(&dav, &home, name, color, kind)?;
        let mut c = new_calendar(name.into(), color.into(), SOURCE_CALDAV);
        c.kind = kind.into();
        c.account_id = Some(acc.id);
        c.remote_url = Some(url);
        c.position = self.db.calendars()?.len() as i64;
        self.db.save_calendar(&mut c)?;
        Ok(c)
    }
}

/// Sincroniza una o todas las cuentas CalDAV con una conexión propia (no bloquea la interfaz).
pub fn sync_accounts(path: &Path, password: &str, account_id: Option<&str>) -> Result<Vec<(String, std::result::Result<SyncStats, String>)>> {
    let db = Db::open(path, password)?;
    let mut out = vec![];
    for mut acc in db.accounts()?.into_iter().filter(|a| account_id.map(|id| id == a.id).unwrap_or(true)) {
        let res = (|| -> Result<SyncStats> {
            let dav = Dav::new(&acc.username, &acc.password)?;
            let mut total = SyncStats::default();
            for cal in db.calendars()?.into_iter().filter(|c| c.account_id.as_deref() == Some(&acc.id)) {
                let pending = db.remote_meta("events", &cal.id)?.iter().any(|m| m.dirty)
                    || db.remote_meta("tasks", &cal.id)?.iter().any(|m| m.dirty);
                let remote_ctag = caldav::ctag(&dav, cal.remote_url.as_deref().unwrap_or(""));
                if !pending && remote_ctag.is_some() && remote_ctag == cal.ctag {
                    continue; // nada nuevo en ningún lado
                }
                let s = caldav::sync_calendar(&db, &dav, &cal)?;
                let mut c = db.calendar(&cal.id)?;
                c.ctag = caldav::ctag(&dav, cal.remote_url.as_deref().unwrap_or(""));
                db.save_calendar(&mut c)?;
                total.uploaded += s.uploaded;
                total.downloaded += s.downloaded;
                total.deleted_local += s.deleted_local;
                total.deleted_remote += s.deleted_remote;
                total.conflicts += s.conflicts;
            }
            Ok(total)
        })();
        match &res {
            Ok(_) => {
                acc.last_sync = Some(time::now_utc_string());
                acc.last_error = None;
            }
            Err(e) => acc.last_error = Some(e.to_string()),
        }
        db.save_account(&acc)?;
        out.push((acc.id.clone(), res.map_err(|e| e.to_string())));
    }
    Ok(out)
}

fn new_calendar(name: String, color: String, source: &str) -> Calendar {
    Calendar {
        id: String::new(),
        name,
        color,
        kind: "both".into(),
        source: source.into(),
        visible: true,
        position: 0,
        ics_path: None,
        account_id: None,
        remote_url: None,
        ctag: None,
        readonly: false,
    }
}

fn file_stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Calendario".into())
}

fn host_of(url: &str) -> String {
    reqwest::Url::parse(url).ok().and_then(|u| u.host_str().map(|h| h.to_string())).unwrap_or_else(|| "CalDAV".into())
}

fn palette(i: usize) -> String {
    ["#007AFF", "#34C759", "#AF52DE", "#FF9500", "#FF2D55", "#5AC8FA", "#FFCC00"][i % 7].to_string()
}

/// Corta una regla añadiendo UNTIL justo antes de `occ` (para «esta y las siguientes»).
fn with_until(rule: &str, occ: &str, tzid: &str, all_day: bool) -> String {
    let base = strip_count_until(rule);
    let d = time::parse_local(occ).unwrap_or_default();
    let until = if all_day {
        (d - Duration::days(1)).format("%Y%m%d").to_string()
    } else {
        (time::to_utc(&d, tzid) - Duration::seconds(1)).format("%Y%m%dT%H%M%SZ").to_string()
    };
    format!("{base};UNTIL={until}")
}

fn strip_count_until(rule: &str) -> String {
    rule.trim_start_matches("RRULE:")
        .split(';')
        .filter(|p| !p.starts_with("COUNT=") && !p.starts_with("UNTIL=") && !p.is_empty())
        .collect::<Vec<_>>()
        .join(";")
}
