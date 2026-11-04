//! Expansión de recurrencias (RRULE, RFC 5545) respetando zonas horarias y cambios de horario.
use crate::model::{Event, Occurrence};
use crate::time;
use chrono::{DateTime, Duration, NaiveDateTime, TimeZone, Utc};
use rrule::{RRuleSet, Tz as RTz};

const MAX_OCCURRENCES: u16 = 2000;

fn ical_local(dt: &NaiveDateTime) -> String {
    dt.format("%Y%m%dT%H%M%S").to_string()
}

/// Construye el texto DTSTART/RRULE/EXDATE para el crate `rrule`.
fn ruleset_text(start: &NaiveDateTime, tzid: &str, rrule: &str, exdates: &[NaiveDateTime]) -> String {
    let rule = rrule.trim().trim_start_matches("RRULE:");
    let floating_utc = tzid.is_empty() || tzid == "UTC";
    let mut s = if floating_utc {
        format!("DTSTART:{}Z\nRRULE:{}", ical_local(start), rule)
    } else {
        format!("DTSTART;TZID={}:{}\nRRULE:{}", tzid, ical_local(start), rule)
    };
    for ex in exdates {
        if floating_utc {
            s.push_str(&format!("\nEXDATE:{}Z", ical_local(ex)));
        } else {
            s.push_str(&format!("\nEXDATE;TZID={}:{}", tzid, ical_local(ex)));
        }
    }
    s
}

fn parse_set(start: &NaiveDateTime, tzid: &str, rrule: &str, exdates: &[NaiveDateTime]) -> Option<RRuleSet> {
    let txt = ruleset_text(start, tzid, rrule, exdates);
    txt.parse::<RRuleSet>().ok()
}

/// Comprueba que una regla es válida (para validar lo que escribe el usuario).
pub fn validate(rrule: &str) -> bool {
    let start = time::parse_local("2026-01-05T09:00").unwrap();
    parse_set(&start, "UTC", rrule, &[]).is_some()
}

fn rutc(dt: DateTime<Utc>) -> DateTime<RTz> {
    dt.with_timezone(&RTz::UTC)
}

/// Inicios (hora local de la zona del evento) de las ocurrencias que se solapan con [from, to).
pub fn event_starts(e: &Event, from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<NaiveDateTime> {
    let Some(start) = time::parse_local(&e.start) else { return vec![] };
    let end = time::parse_local(&e.end).unwrap_or(start);
    let dur = end - start;
    // Los eventos de día completo son "flotantes": se interpretan igual en cualquier zona.
    let tzid = if e.all_day { "UTC" } else { e.tzid.as_str() };
    let to_u = |n: &NaiveDateTime| if e.all_day { Utc.from_utc_datetime(n) } else { time::to_utc(n, tzid) };
    let rule = e.rrule.as_deref().unwrap_or("").trim();
    if rule.is_empty() {
        let s = to_u(&start);
        let en = to_u(&end).max(s + Duration::seconds(1));
        return if s < to && en > from { vec![start] } else { vec![] };
    }
    let exdates: Vec<NaiveDateTime> = e.exdates.iter().filter_map(|x| time::parse_local(x)).collect();
    let Some(set) = parse_set(&start, tzid, rule, &exdates) else {
        // Regla no reconocida: se muestra al menos la primera ocurrencia.
        return vec![start];
    };
    let window_from = from - dur - Duration::seconds(1);
    let res = set.after(rutc(window_from)).before(rutc(to - Duration::seconds(1))).all(MAX_OCCURRENCES);
    res.dates
        .into_iter()
        .map(|d| {
            if e.all_day {
                d.with_timezone(&Utc).naive_utc()
            } else {
                d.with_timezone(&time::tz(tzid)).naive_local()
            }
        })
        .filter(|s| {
            let su = to_u(s);
            let eu = to_u(&(*s + dur)).max(su + Duration::seconds(1));
            su < to && eu > from
        })
        .collect()
}

/// Ocurrencias de un evento en [from, to), con horas expresadas en la zona de la vista (`view_tz`).
pub fn occurrences(e: &Event, color: &str, from: DateTime<Utc>, to: DateTime<Utc>, view_tz: &str) -> Vec<Occurrence> {
    let start = time::parse_local(&e.start).unwrap_or_default();
    let end = time::parse_local(&e.end).unwrap_or(start);
    let dur = end - start;
    let recurring = e.rrule.as_deref().map(|r| !r.trim().is_empty()).unwrap_or(false);
    event_starts(e, from, to)
        .into_iter()
        .map(|s| {
            let (vs, ve) = if e.all_day {
                (s, s + dur)
            } else {
                let su = time::to_utc(&s, &e.tzid);
                let eu = time::to_utc(&(s + dur), &e.tzid);
                (time::utc_to_local(&su, view_tz), time::utc_to_local(&eu, view_tz))
            };
            let fmt = |d: &NaiveDateTime| if e.all_day { time::fmt_date(d) } else { time::fmt_local(d) };
            Occurrence {
                event_id: e.id.clone(),
                calendar_id: e.calendar_id.clone(),
                color: color.to_string(),
                title: e.title.clone(),
                location: e.location.clone(),
                notes: e.notes.clone(),
                all_day: e.all_day,
                start: fmt(&vs),
                end: fmt(&ve),
                original_start: fmt(&s),
                recurring,
                attachments: 0,
            }
        })
        .collect()
}

/// Siguiente vencimiento de una tarea recurrente estrictamente posterior a `after` (hora local de `tzid`).
pub fn next_after(first: &NaiveDateTime, tzid: &str, rrule: &str, after: &NaiveDateTime) -> Option<NaiveDateTime> {
    let tzid = if tzid.is_empty() { "UTC" } else { tzid };
    let set = parse_set(first, tzid, rrule, &[])?;
    let after_u = time::to_utc(after, tzid) + Duration::seconds(1);
    let res = set.after(rutc(after_u)).all(1);
    res.dates.first().map(|d| d.with_timezone(&time::tz(tzid)).naive_local())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(start: &str, end: &str, rrule: Option<&str>) -> Event {
        Event {
            id: "e".into(),
            calendar_id: "c".into(),
            title: "Daily".into(),
            start: start.into(),
            end: end.into(),
            tzid: "Europe/Madrid".into(),
            rrule: rrule.map(|s| s.into()),
            ..Default::default()
        }
    }

    fn u(s: &str) -> DateTime<Utc> {
        time::to_utc(&time::parse_local(s).unwrap(), "Europe/Madrid")
    }

    #[test]
    fn weekly_keeps_local_time_across_dst() {
        // Todos los lunes a las 9:30 desde el 19 oct; el 26 oct cambia el horario.
        let e = ev("2026-10-19T09:30:00", "2026-10-19T09:45:00", Some("FREQ=WEEKLY;BYDAY=MO"));
        let occ = occurrences(&e, "#000", u("2026-10-19T00:00"), u("2026-11-03T00:00"), "Europe/Madrid");
        let starts: Vec<_> = occ.iter().map(|o| o.start.clone()).collect();
        assert_eq!(starts, vec!["2026-10-19T09:30:00", "2026-10-26T09:30:00", "2026-11-02T09:30:00"]);
    }

    #[test]
    fn exdates_and_overlap() {
        let mut e = ev("2026-11-02T09:00:00", "2026-11-02T10:00:00", Some("FREQ=DAILY;COUNT=5"));
        e.exdates = vec!["2026-11-04T09:00:00".into()];
        let occ = occurrences(&e, "#000", u("2026-11-02T09:30"), u("2026-11-10T00:00"), "Europe/Madrid");
        assert_eq!(occ.len(), 4); // 2 (en curso), 3, 5, 6 — el 4 excluido
        assert!(occ.iter().all(|o| !o.start.starts_with("2026-11-04")));
    }

    #[test]
    fn single_event_overlap() {
        let e = ev("2026-11-03T10:00:00", "2026-11-03T11:00:00", None);
        assert_eq!(event_starts(&e, u("2026-11-03T10:30"), u("2026-11-03T12:00")).len(), 1);
        assert_eq!(event_starts(&e, u("2026-11-03T11:00"), u("2026-11-03T12:00")).len(), 0);
    }

    #[test]
    fn all_day_is_floating() {
        let mut e = ev("2026-11-09", "2026-11-10", Some("FREQ=YEARLY"));
        e.all_day = true;
        let occ = occurrences(&e, "#000", u("2027-11-01T00:00"), u("2027-11-30T00:00"), "America/New_York");
        assert_eq!(occ.len(), 1);
        assert_eq!(occ[0].start, "2027-11-09");
    }

    #[test]
    fn task_next_due() {
        let first = time::parse_local("2026-11-03T10:00").unwrap();
        let n = next_after(&first, "Europe/Madrid", "FREQ=WEEKLY;INTERVAL=2", &first).unwrap();
        assert_eq!(time::fmt_local(&n), "2026-11-17T10:00:00");
        assert!(validate("FREQ=MONTHLY;BYMONTHDAY=1"));
        assert!(!validate("FREQ=NUNCA"));
    }
}
