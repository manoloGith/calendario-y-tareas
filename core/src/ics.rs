//! Lectura y escritura de iCalendar (RFC 5545): VEVENT y VTODO, con subtareas (RELATED-TO),
//! etiquetas (CATEGORIES), recurrencias (RRULE/EXDATE), avisos (VALARM) y zonas horarias (TZID).
use crate::model::{Event, Task};
use crate::time;
use chrono::{Duration, NaiveDateTime, TimeZone, Utc};

#[derive(Debug, Clone)]
pub struct Prop {
    pub name: String,
    pub params: Vec<(String, String)>,
    pub value: String,
}

impl Prop {
    fn param(&self, k: &str) -> Option<&str> {
        self.params.iter().find(|(n, _)| n.eq_ignore_ascii_case(k)).map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone, Default)]
pub struct Component {
    pub name: String,
    pub props: Vec<Prop>,
    pub children: Vec<Component>,
}

impl Component {
    fn get(&self, name: &str) -> Option<&Prop> {
        self.props.iter().find(|p| p.name == name)
    }
    fn all(&self, name: &str) -> impl Iterator<Item = &Prop> {
        let n = name.to_string();
        self.props.iter().filter(move |p| p.name == n)
    }
    fn text(&self, name: &str) -> String {
        self.get(name).map(|p| unescape(&p.value)).unwrap_or_default()
    }
}

fn unfold(input: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for raw in input.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if (line.starts_with(' ') || line.starts_with('\t')) && !out.is_empty() {
            out.last_mut().unwrap().push_str(&line[1..]);
        } else if !line.is_empty() {
            out.push(line.to_string());
        }
    }
    out
}

fn parse_line(line: &str) -> Option<Prop> {
    // Busca el ':' que separa nombre/parámetros del valor, ignorando los que van entre comillas.
    let mut in_q = false;
    let mut colon = None;
    for (i, c) in line.char_indices() {
        match c {
            '"' => in_q = !in_q,
            ':' if !in_q => {
                colon = Some(i);
                break;
            }
            _ => {}
        }
    }
    let colon = colon?;
    let (head, value) = (&line[..colon], &line[colon + 1..]);
    let mut parts = head.split(';');
    let name = parts.next()?.trim().to_ascii_uppercase();
    let params = parts
        .filter_map(|p| {
            let (k, v) = p.split_once('=')?;
            Some((k.trim().to_ascii_uppercase(), v.trim_matches('"').to_string()))
        })
        .collect();
    Some(Prop { name, params, value: value.to_string() })
}

/// Analiza un documento iCalendar y devuelve los componentes raíz (normalmente VCALENDAR).
pub fn parse(input: &str) -> Vec<Component> {
    let mut stack: Vec<Component> = vec![];
    let mut roots = vec![];
    for line in unfold(input) {
        let Some(p) = parse_line(&line) else { continue };
        if p.name == "BEGIN" {
            stack.push(Component { name: p.value.trim().to_ascii_uppercase(), ..Default::default() });
        } else if p.name == "END" {
            if let Some(c) = stack.pop() {
                match stack.last_mut() {
                    Some(parent) => parent.children.push(c),
                    None => roots.push(c),
                }
            }
        } else if let Some(cur) = stack.last_mut() {
            cur.props.push(p);
        }
    }
    roots
}

pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') | Some('N') => out.push('\n'),
                Some(o) => out.push(o),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace(';', "\\;").replace(',', "\\,").replace("\r\n", "\\n").replace('\n', "\\n")
}

/// Convierte un valor de fecha iCalendar a (hora local, tzid, es_fecha).
fn parse_dt(p: &Prop, default_tz: &str) -> Option<(NaiveDateTime, String, bool)> {
    let v = p.value.trim();
    let is_date = p.param("VALUE").map(|x| x.eq_ignore_ascii_case("DATE")).unwrap_or(false) || v.len() == 8;
    if is_date {
        let d = chrono::NaiveDate::parse_from_str(&v[..8.min(v.len())], "%Y%m%d").ok()?;
        return Some((d.and_hms_opt(0, 0, 0)?, default_tz.to_string(), true));
    }
    if let Some(u) = v.strip_suffix('Z') {
        let n = NaiveDateTime::parse_from_str(u, "%Y%m%dT%H%M%S").ok()?;
        let utc = Utc.from_utc_datetime(&n);
        return Some((time::utc_to_local(&utc, default_tz), default_tz.to_string(), false));
    }
    let n = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S").ok()?;
    let tzid = p
        .param("TZID")
        .map(|t| t.trim_start_matches('/').to_string())
        .filter(|t| t.parse::<chrono_tz::Tz>().is_ok())
        .or_else(|| p.param("TZID").and_then(windows_tz))
        .unwrap_or_else(|| default_tz.to_string());
    Some((n, tzid, false))
}

/// Algunos servidores (Exchange/Outlook) usan nombres de zona de Windows.
fn windows_tz(name: &str) -> Option<String> {
    let m = [
        ("Romance Standard Time", "Europe/Paris"),
        ("W. Europe Standard Time", "Europe/Berlin"),
        ("GMT Standard Time", "Europe/London"),
        ("Central European Standard Time", "Europe/Warsaw"),
        ("Eastern Standard Time", "America/New_York"),
        ("Pacific Standard Time", "America/Los_Angeles"),
        ("UTC", "UTC"),
    ];
    m.iter().find(|(w, _)| *w == name).map(|(_, i)| i.to_string())
}

fn parse_duration(s: &str) -> Option<Duration> {
    // P1D, PT1H30M, -PT15M, P1W
    let neg = s.starts_with('-');
    let s = s.trim_start_matches(['-', '+']).strip_prefix('P')?;
    let mut total = Duration::zero();
    let mut num = String::new();
    let mut in_time = false;
    for c in s.chars() {
        match c {
            'T' => in_time = true,
            '0'..='9' => num.push(c),
            u => {
                let n: i64 = num.parse().ok()?;
                num.clear();
                total += match (u, in_time) {
                    ('W', _) => Duration::weeks(n),
                    ('D', _) => Duration::days(n),
                    ('H', true) => Duration::hours(n),
                    ('M', true) => Duration::minutes(n),
                    ('S', true) => Duration::seconds(n),
                    _ => return None,
                };
            }
        }
    }
    Some(if neg { -total } else { total })
}

fn alarms(c: &Component) -> Vec<i64> {
    c.children
        .iter()
        .filter(|a| a.name == "VALARM")
        .filter_map(|a| a.get("TRIGGER"))
        .filter_map(|t| parse_duration(t.value.trim()))
        .map(|d| -d.num_minutes())
        .filter(|m| *m >= 0)
        .collect()
}

fn categories(c: &Component) -> Vec<String> {
    c.all("CATEGORIES")
        .flat_map(|p| {
            // Las comas sin escapar separan categorías.
            let mut out = vec![];
            let mut cur = String::new();
            let mut esc = false;
            for ch in p.value.chars() {
                if esc {
                    cur.push(ch);
                    esc = false;
                } else if ch == '\\' {
                    esc = true;
                } else if ch == ',' {
                    out.push(cur.clone());
                    cur.clear();
                } else {
                    cur.push(ch);
                }
            }
            out.push(cur);
            out
        })
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Contenido de un archivo .ics como eventos y tareas (el calendario de destino se asigna después).
#[derive(Debug, Default)]
pub struct Parsed {
    pub events: Vec<Event>,
    pub tasks: Vec<Task>,
    pub name: Option<String>,
    pub color: Option<String>,
}

pub fn read(input: &str, default_tz: &str) -> Parsed {
    let mut out = Parsed::default();
    let mut overrides: Vec<(String, String)> = vec![]; // (uid, recurrence-id local) → se excluyen del maestro
    let mut detached: Vec<Event> = vec![];
    for root in parse(input) {
        let comps: Vec<&Component> = if root.name == "VCALENDAR" { root.children.iter().collect() } else { vec![&root] };
        if root.name == "VCALENDAR" {
            out.name = root.get("X-WR-CALNAME").map(|p| unescape(&p.value));
            out.color = root.get("X-APPLE-CALENDAR-COLOR").or(root.get("COLOR")).map(|p| p.value.clone());
        }
        for c in comps {
            match c.name.as_str() {
                "VEVENT" => {
                    let Some((start, tzid, is_date)) = c.get("DTSTART").and_then(|p| parse_dt(p, default_tz)) else { continue };
                    let end = c
                        .get("DTEND")
                        .and_then(|p| parse_dt(p, default_tz))
                        .map(|(e, etz, _)| {
                            if etz != tzid && !is_date {
                                time::utc_to_local(&time::to_utc(&e, &etz), &tzid)
                            } else {
                                e
                            }
                        })
                        .or_else(|| c.get("DURATION").and_then(|d| parse_duration(&d.value)).map(|d| start + d))
                        .unwrap_or(if is_date { start + Duration::days(1) } else { start + Duration::hours(1) });
                    let fmt = |d: &NaiveDateTime| if is_date { time::fmt_date(d) } else { time::fmt_local(d) };
                    let uid = c.text("UID");
                    let uid = if uid.is_empty() { uuid::Uuid::new_v4().to_string() } else { uid };
                    let mut exdates = vec![];
                    for p in c.all("EXDATE") {
                        for v in p.value.split(',') {
                            let pp = Prop { value: v.to_string(), ..p.clone() };
                            if let Some((d, etz, _)) = parse_dt(&pp, default_tz) {
                                let d = if etz != tzid { time::utc_to_local(&time::to_utc(&d, &etz), &tzid) } else { d };
                                exdates.push(fmt(&d));
                            }
                        }
                    }
                    let ev = Event {
                        id: uid.clone(),
                        calendar_id: String::new(),
                        title: c.text("SUMMARY"),
                        notes: c.text("DESCRIPTION"),
                        location: c.text("LOCATION"),
                        all_day: is_date,
                        start: fmt(&start),
                        end: fmt(&end),
                        tzid: tzid.clone(),
                        rrule: c.get("RRULE").map(|p| p.value.clone()),
                        exdates,
                        alarms: alarms(c),
                        created: String::new(),
                        updated: c.get("LAST-MODIFIED").map(|p| p.value.clone()).unwrap_or_default(),
                    };
                    if let Some(rid) = c.get("RECURRENCE-ID").and_then(|p| parse_dt(p, default_tz)) {
                        // Ocurrencia modificada: se guarda como evento propio y se excluye del maestro.
                        overrides.push((uid.clone(), fmt(&rid.0)));
                        let mut d = ev;
                        d.id = format!("{}::{}", uid, fmt(&rid.0));
                        d.rrule = None;
                        detached.push(d);
                    } else {
                        out.events.push(ev);
                    }
                }
                "VTODO" => {
                    let uid = c.text("UID");
                    let due = c.get("DUE").or(c.get("DTSTART")).and_then(|p| parse_dt(p, default_tz));
                    let status = c.text("STATUS").to_ascii_uppercase();
                    let completed = status == "COMPLETED" || c.get("COMPLETED").is_some();
                    let prio: i64 = c.text("PRIORITY").parse().unwrap_or(0);
                    // RFC 5545: 1-4 alta, 5 media, 6-9 baja.
                    let priority = match prio {
                        1..=4 => 3,
                        5 => 2,
                        6..=9 => 1,
                        _ => 0,
                    };
                    let parent = c
                        .all("RELATED-TO")
                        .find(|p| p.param("RELTYPE").map(|r| r.eq_ignore_ascii_case("PARENT")).unwrap_or(true))
                        .map(|p| p.value.trim().to_string());
                    let mut tags = vec![];
                    let mut flagged = false;
                    let mut section = String::new();
                    for cat in categories(c) {
                        if cat.eq_ignore_ascii_case("flagged") || cat == "X-FLAGGED" {
                            flagged = true;
                        } else if let Some(s) = cat.strip_prefix("section:") {
                            section = s.to_string();
                        } else {
                            tags.push(crate::db::normalize_tag(&cat));
                        }
                    }
                    if c.get("X-CALENDARIO-FLAGGED").map(|p| p.value == "1").unwrap_or(false) {
                        flagged = true;
                    }
                    if let Some(s) = c.get("X-CALENDARIO-SECTION") {
                        section = unescape(&s.value);
                    }
                    out.tasks.push(Task {
                        id: if uid.is_empty() { uuid::Uuid::new_v4().to_string() } else { uid },
                        list_id: String::new(),
                        parent_id: parent,
                        title: c.text("SUMMARY"),
                        notes: c.text("DESCRIPTION"),
                        due: due.as_ref().map(|(d, _, is_date)| if *is_date { time::fmt_date(d) } else { time::fmt_local(d) }),
                        tzid: due.map(|(_, t, _)| t).unwrap_or_else(|| default_tz.to_string()),
                        priority,
                        flagged,
                        tags,
                        rrule: c.get("RRULE").map(|p| p.value.clone()),
                        completed,
                        completed_at: c.get("COMPLETED").map(|p| p.value.clone()),
                        section,
                        position: c.text("X-APPLE-SORT-ORDER").parse().unwrap_or(0),
                        alarm: alarms(c).first().copied(),
                        created: String::new(),
                        updated: c.get("LAST-MODIFIED").map(|p| p.value.clone()).unwrap_or_default(),
                    });
                }
                _ => {}
            }
        }
    }
    for (uid, rid) in overrides {
        if let Some(m) = out.events.iter_mut().find(|e| e.id == uid) {
            if !m.exdates.contains(&rid) {
                m.exdates.push(rid);
            }
        }
    }
    out.events.extend(detached);
    out
}

// ------------------------------------------------------------------ escritura

fn fold(line: &str) -> String {
    // Pliega a 75 octetos sin partir caracteres UTF-8.
    let mut out = String::new();
    let mut count = 0;
    for ch in line.chars() {
        let len = ch.len_utf8();
        if count + len > 75 {
            out.push_str("\r\n ");
            count = 1;
        }
        out.push(ch);
        count += len;
    }
    out.push_str("\r\n");
    out
}

fn dt_prop(name: &str, local: &str, tzid: &str, all_day: bool) -> String {
    let Some(d) = time::parse_local(local) else { return String::new() };
    if all_day || !local.contains('T') {
        format!("{name};VALUE=DATE:{}", d.format("%Y%m%d"))
    } else if tzid.is_empty() || tzid == "UTC" {
        format!("{name}:{}Z", d.format("%Y%m%dT%H%M%S"))
    } else {
        format!("{name};TZID={tzid}:{}", d.format("%Y%m%dT%H%M%S"))
    }
}

fn stamp(s: &str) -> String {
    // "2026-11-03T08:00:00Z" → "20261103T080000Z"
    let c: String = s.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if c.len() >= 15 { c } else { Utc::now().format("%Y%m%dT%H%M%SZ").to_string() }
}

fn valarm(minutes: i64) -> Vec<String> {
    vec![
        "BEGIN:VALARM".into(),
        "ACTION:DISPLAY".into(),
        "DESCRIPTION:Recordatorio".into(),
        format!("TRIGGER:-PT{minutes}M"),
        "END:VALARM".into(),
    ]
}

pub fn event_lines(e: &Event) -> Vec<String> {
    let mut l = vec!["BEGIN:VEVENT".to_string(), format!("UID:{}", e.id)];
    l.push(format!("DTSTAMP:{}", stamp(&e.updated)));
    l.push(format!("LAST-MODIFIED:{}", stamp(&e.updated)));
    l.push(format!("SUMMARY:{}", escape(&e.title)));
    l.push(dt_prop("DTSTART", &e.start, &e.tzid, e.all_day));
    l.push(dt_prop("DTEND", &e.end, &e.tzid, e.all_day));
    if !e.notes.is_empty() {
        l.push(format!("DESCRIPTION:{}", escape(&e.notes)));
    }
    if !e.location.is_empty() {
        l.push(format!("LOCATION:{}", escape(&e.location)));
    }
    if let Some(r) = e.rrule.as_ref().filter(|r| !r.is_empty()) {
        l.push(format!("RRULE:{}", r.trim_start_matches("RRULE:")));
    }
    for x in &e.exdates {
        l.push(dt_prop("EXDATE", x, &e.tzid, e.all_day));
    }
    for a in &e.alarms {
        l.extend(valarm(*a));
    }
    l.push("END:VEVENT".into());
    l
}

pub fn task_lines(t: &Task) -> Vec<String> {
    let mut l = vec!["BEGIN:VTODO".to_string(), format!("UID:{}", t.id)];
    l.push(format!("DTSTAMP:{}", stamp(&t.updated)));
    l.push(format!("LAST-MODIFIED:{}", stamp(&t.updated)));
    l.push(format!("SUMMARY:{}", escape(&t.title)));
    if !t.notes.is_empty() {
        l.push(format!("DESCRIPTION:{}", escape(&t.notes)));
    }
    if let Some(d) = &t.due {
        l.push(dt_prop("DUE", d, &t.tzid, !d.contains('T')));
    }
    let prio = match t.priority {
        3 => 1,
        2 => 5,
        1 => 9,
        _ => 0,
    };
    if prio > 0 {
        l.push(format!("PRIORITY:{prio}"));
    }
    if let Some(p) = &t.parent_id {
        l.push(format!("RELATED-TO;RELTYPE=PARENT:{p}"));
    }
    let mut cats: Vec<String> = t.tags.iter().map(|s| escape(s.trim_start_matches('#'))).collect();
    if t.flagged {
        l.push("X-CALENDARIO-FLAGGED:1".into());
    }
    if !t.section.is_empty() {
        l.push(format!("X-CALENDARIO-SECTION:{}", escape(&t.section)));
    }
    if !cats.is_empty() {
        cats.sort();
        l.push(format!("CATEGORIES:{}", cats.join(",")));
    }
    if let Some(r) = t.rrule.as_ref().filter(|r| !r.is_empty()) {
        l.push(format!("RRULE:{}", r.trim_start_matches("RRULE:")));
    }
    if t.completed {
        l.push("STATUS:COMPLETED".into());
        l.push(format!("COMPLETED:{}", stamp(t.completed_at.as_deref().unwrap_or(&t.updated))));
        l.push("PERCENT-COMPLETE:100".into());
    } else {
        l.push("STATUS:NEEDS-ACTION".into());
    }
    l.push(format!("X-APPLE-SORT-ORDER:{}", t.position));
    if let Some(a) = t.alarm {
        if t.due_has_time() {
            l.extend(valarm(a));
        }
    }
    l.push("END:VTODO".into());
    l
}

pub fn calendar_doc(name: &str, color: &str, events: &[Event], tasks: &[Task]) -> String {
    let mut out = String::new();
    let mut push = |s: &str| out.push_str(&fold(s));
    push("BEGIN:VCALENDAR");
    push("VERSION:2.0");
    push("PRODID:-//Calendario y Tareas//ES");
    push("CALSCALE:GREGORIAN");
    if !name.is_empty() {
        push(&format!("X-WR-CALNAME:{}", escape(name)));
    }
    if !color.is_empty() {
        push(&format!("X-APPLE-CALENDAR-COLOR:{color}"));
    }
    for e in events {
        for line in event_lines(e) {
            if !line.is_empty() {
                push(&line);
            }
        }
    }
    for t in tasks {
        for line in task_lines(t) {
            push(&line);
        }
    }
    push("END:VCALENDAR");
    out
}

/// Documento con un único objeto (lo que se sube a cada recurso CalDAV).
pub fn single_event(e: &Event) -> String {
    calendar_doc("", "", std::slice::from_ref(e), &[])
}

pub fn single_task(t: &Task) -> String {
    calendar_doc("", "", &[], std::slice::from_ref(t))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:Trabajo\r\nBEGIN:VEVENT\r\nUID:abc@x\r\n\
DTSTART;TZID=Europe/Madrid:20261102T093000\r\nDTEND;TZID=Europe/Madrid:20261102T094500\r\nSUMMARY:Daily del eq\r\n uipo\\, sala 2\r\n\
RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR\r\nEXDATE;TZID=Europe/Madrid:20261109T093000\r\nBEGIN:VALARM\r\nTRIGGER:-PT10M\r\n\
ACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:abc@x\r\nRECURRENCE-ID;TZID=Europe/Madrid:20261103T093000\r\n\
DTSTART;TZID=Europe/Madrid:20261103T100000\r\nDTEND;TZID=Europe/Madrid:20261103T101500\r\nSUMMARY:Daily (movida)\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:fest\r\nDTSTART;VALUE=DATE:20261109\r\nSUMMARY:Almudena\r\nEND:VEVENT\r\n\
BEGIN:VTODO\r\nUID:t1\r\nSUMMARY:Preparar slides\r\nDUE;TZID=Europe/Madrid:20261103T100000\r\nPRIORITY:1\r\nCATEGORIES:sprint,Cliente\r\n\
RRULE:FREQ=WEEKLY;INTERVAL=2\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:t2\r\nSUMMARY:Recopilar métricas\r\nRELATED-TO;RELTYPE=PARENT:t1\r\n\
STATUS:COMPLETED\r\nEND:VTODO\r\nEND:VCALENDAR\r\n";

    #[test]
    fn reads_events_tasks_and_overrides() {
        let p = read(SAMPLE, "Europe/Madrid");
        assert_eq!(p.name.as_deref(), Some("Trabajo"));
        let daily = p.events.iter().find(|e| e.id == "abc@x").unwrap();
        assert_eq!(daily.title, "Daily del equipo, sala 2");
        assert_eq!(daily.start, "2026-11-02T09:30:00");
        assert_eq!(daily.alarms, vec![10]);
        assert_eq!(daily.exdates, vec!["2026-11-09T09:30:00", "2026-11-03T09:30:00"]);
        assert!(p.events.iter().any(|e| e.id.starts_with("abc@x::") && e.start == "2026-11-03T10:00:00"));
        let fest = p.events.iter().find(|e| e.id == "fest").unwrap();
        assert!(fest.all_day);
        assert_eq!(fest.end, "2026-11-10");
        let t1 = p.tasks.iter().find(|t| t.id == "t1").unwrap();
        assert_eq!(t1.priority, 3);
        assert_eq!(t1.tags, vec!["#sprint", "#cliente"]);
        let t2 = p.tasks.iter().find(|t| t.id == "t2").unwrap();
        assert_eq!(t2.parent_id.as_deref(), Some("t1"));
        assert!(t2.completed);
    }

    #[test]
    fn roundtrip() {
        let p = read(SAMPLE, "Europe/Madrid");
        let doc = calendar_doc("Trabajo", "#007AFF", &p.events, &p.tasks);
        assert!(doc.lines().all(|l| l.len() <= 76));
        let q = read(&doc, "Europe/Madrid");
        assert_eq!(q.events.len(), p.events.len());
        assert_eq!(q.tasks.len(), 2);
        let daily = q.events.iter().find(|e| e.id == "abc@x").unwrap();
        assert_eq!(daily.title, "Daily del equipo, sala 2");
        assert_eq!(daily.rrule.as_deref(), Some("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"));
        let t1 = q.tasks.iter().find(|t| t.id == "t1").unwrap();
        assert_eq!(t1.tags, vec!["#cliente", "#sprint"]);
        assert_eq!(t1.due.as_deref(), Some("2026-11-03T10:00:00"));
    }

    #[test]
    fn utc_values_convert_to_local() {
        let doc = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u\nDTSTART:20261103T090000Z\nDURATION:PT90M\nSUMMARY:x\nEND:VEVENT\nEND:VCALENDAR\n";
        let p = read(doc, "Europe/Madrid");
        assert_eq!(p.events[0].start, "2026-11-03T10:00:00");
        assert_eq!(p.events[0].end, "2026-11-03T11:30:00");
    }
}
