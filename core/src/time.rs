//! Utilidades de fechas: formato local "YYYY-MM-DDTHH:MM:SS", zonas horarias IANA y conversión a UTC.
use chrono::{DateTime, Duration, LocalResult, NaiveDate, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;

pub const FMT: &str = "%Y-%m-%dT%H:%M:%S";
pub const DATE_FMT: &str = "%Y-%m-%d";

/// Zona horaria del sistema (IANA). Si no se puede detectar, UTC.
pub fn system_tzid() -> String {
    if let Ok(tz) = std::env::var("CALENDARIO_TZ") {
        if tz.parse::<Tz>().is_ok() {
            return tz;
        }
    }
    iana_time_zone::get_timezone()
        .ok()
        .filter(|t| t.parse::<Tz>().is_ok())
        .unwrap_or_else(|| "UTC".to_string())
}

pub fn tz(tzid: &str) -> Tz {
    if tzid.is_empty() {
        return system_tzid().parse().unwrap_or(Tz::UTC);
    }
    tzid.parse().unwrap_or(Tz::UTC)
}

/// Acepta "YYYY-MM-DD", "YYYY-MM-DDTHH:MM" o "YYYY-MM-DDTHH:MM:SS".
pub fn parse_local(s: &str) -> Option<NaiveDateTime> {
    let s = s.trim();
    if let Ok(dt) = NaiveDateTime::parse_from_str(s, FMT) {
        return Some(dt);
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M") {
        return Some(dt);
    }
    if let Ok(d) = NaiveDate::parse_from_str(s, DATE_FMT) {
        return d.and_hms_opt(0, 0, 0);
    }
    None
}

pub fn fmt_local(dt: &NaiveDateTime) -> String {
    dt.format(FMT).to_string()
}

pub fn fmt_date(dt: &NaiveDateTime) -> String {
    dt.format(DATE_FMT).to_string()
}

/// Convierte una hora local de la zona `tzid` a UTC, resolviendo horas ambiguas o inexistentes (cambios de horario).
pub fn to_utc(local: &NaiveDateTime, tzid: &str) -> DateTime<Utc> {
    let z = tz(tzid);
    match z.from_local_datetime(local) {
        LocalResult::Single(d) => d.with_timezone(&Utc),
        LocalResult::Ambiguous(a, _) => a.with_timezone(&Utc),
        LocalResult::None => match z.from_local_datetime(&(*local + Duration::hours(1))) {
            LocalResult::Single(d) | LocalResult::Ambiguous(d, _) => d.with_timezone(&Utc),
            LocalResult::None => Utc.from_utc_datetime(local),
        },
    }
}

pub fn utc_to_local(utc: &DateTime<Utc>, tzid: &str) -> NaiveDateTime {
    utc.with_timezone(&tz(tzid)).naive_local()
}

pub fn now_utc_string() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn now_local(tzid: &str) -> NaiveDateTime {
    utc_to_local(&Utc::now(), tzid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dst_gap_and_overlap_resolve() {
        // 29 mar 2026, 02:30 no existe en Madrid; 25 oct 2026, 02:30 es ambigua.
        let gap = parse_local("2026-03-29T02:30").unwrap();
        assert_eq!(to_utc(&gap, "Europe/Madrid").format("%H:%M").to_string(), "01:30");
        let amb = parse_local("2026-10-25T02:30").unwrap();
        assert_eq!(to_utc(&amb, "Europe/Madrid").format("%H:%M").to_string(), "00:30");
    }

    #[test]
    fn parse_formats() {
        assert!(parse_local("2026-11-03").is_some());
        assert!(parse_local("2026-11-03T10:00").is_some());
        assert!(parse_local("2026-11-03T10:00:00").is_some());
        assert!(parse_local("mañana").is_none());
    }
}
