//! Modelo de datos compartido entre almacenamiento, conectores y la API JSON.
use serde::{Deserialize, Serialize};

/// Origen de un calendario o lista de tareas.
pub const SOURCE_LOCAL: &str = "local";
pub const SOURCE_ICS: &str = "ics";
pub const SOURCE_CALDAV: &str = "caldav";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Calendar {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default = "default_color")]
    pub color: String,
    /// "events", "tasks" o "both"
    #[serde(default = "default_kind")]
    pub kind: String,
    /// "local", "ics" o "caldav"
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(default = "yes")]
    pub visible: bool,
    #[serde(default)]
    pub position: i64,
    /// Ruta del archivo .ics enlazado (source = "ics").
    #[serde(default)]
    pub ics_path: Option<String>,
    /// Cuenta CalDAV a la que pertenece (source = "caldav").
    #[serde(default)]
    pub account_id: Option<String>,
    /// URL de la colección CalDAV.
    #[serde(default)]
    pub remote_url: Option<String>,
    #[serde(default)]
    pub ctag: Option<String>,
    #[serde(default)]
    pub readonly: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub username: String,
    #[serde(default, skip_serializing)]
    pub password: String,
    #[serde(default)]
    pub principal_url: Option<String>,
    #[serde(default)]
    pub home_url: Option<String>,
    #[serde(default)]
    pub last_sync: Option<String>,
    #[serde(default)]
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    #[serde(default)]
    pub id: String,
    pub calendar_id: String,
    pub title: String,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub all_day: bool,
    /// Fecha/hora local en la zona `tzid`: "2026-11-03T10:00:00" o "2026-11-03" si es de día completo.
    pub start: String,
    /// Fin exclusivo, mismo formato que `start`.
    pub end: String,
    #[serde(default)]
    pub tzid: String,
    /// Regla RFC 5545 sin el prefijo "RRULE:", p. ej. "FREQ=WEEKLY;BYDAY=MO".
    #[serde(default)]
    pub rrule: Option<String>,
    /// Ocurrencias excluidas (mismo formato que `start`).
    #[serde(default)]
    pub exdates: Vec<String>,
    /// Avisos: minutos antes del inicio.
    #[serde(default)]
    pub alarms: Vec<i64>,
    #[serde(default)]
    pub created: String,
    #[serde(default)]
    pub updated: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    #[serde(default)]
    pub id: String,
    pub list_id: String,
    #[serde(default)]
    pub parent_id: Option<String>,
    pub title: String,
    #[serde(default)]
    pub notes: String,
    /// "2026-11-03" o "2026-11-03T10:00:00" (hora local en `tzid`).
    #[serde(default)]
    pub due: Option<String>,
    #[serde(default)]
    pub tzid: String,
    /// 0 ninguna, 1 baja, 2 media, 3 alta.
    #[serde(default)]
    pub priority: i64,
    #[serde(default)]
    pub flagged: bool,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub rrule: Option<String>,
    #[serde(default)]
    pub completed: bool,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub section: String,
    #[serde(default)]
    pub position: i64,
    /// Aviso: minutos antes del vencimiento (solo si `due` tiene hora).
    #[serde(default)]
    pub alarm: Option<i64>,
    #[serde(default)]
    pub created: String,
    #[serde(default)]
    pub updated: String,
}

impl Task {
    pub fn due_has_time(&self) -> bool {
        self.due.as_deref().map(|d| d.contains('T')).unwrap_or(false)
    }
}

/// Una ocurrencia concreta de un evento dentro de un rango (expande recurrencias).
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Occurrence {
    pub event_id: String,
    pub calendar_id: String,
    pub color: String,
    pub title: String,
    pub location: String,
    pub notes: String,
    pub all_day: bool,
    /// Inicio de esta ocurrencia en la zona horaria de la vista.
    pub start: String,
    pub end: String,
    /// Inicio original de la ocurrencia en la zona del evento (para excluir o separar).
    pub original_start: String,
    pub recurring: bool,
}

fn default_color() -> String {
    "#007AFF".into()
}
fn default_kind() -> String {
    "both".into()
}
fn default_source() -> String {
    SOURCE_LOCAL.into()
}
fn yes() -> bool {
    true
}
