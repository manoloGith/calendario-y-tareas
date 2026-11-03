//! Captura rápida en lenguaje natural (español), 100 % local.
//! Ejemplos: «Cena con Ana el viernes a las 21h #amigos», «Pagar IBI mañana !!», «Daily cada día laborable a las 9:30».
use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime, NaiveTime, Weekday};
use regex::Regex;
use serde::Serialize;
use std::sync::LazyLock;

#[derive(Debug, Clone, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Quick {
    pub title: String,
    /// "YYYY-MM-DD" o "YYYY-MM-DDTHH:MM:SS"
    pub date: Option<String>,
    pub has_time: bool,
    pub duration_min: i64,
    pub tags: Vec<String>,
    pub priority: i64,
    pub rrule: Option<String>,
}

fn strip_accents(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'á' | 'Á' => 'a',
            'é' | 'É' => 'e',
            'í' | 'Í' => 'i',
            'ó' | 'Ó' => 'o',
            'ú' | 'Ú' | 'ü' => 'u',
            'ñ' | 'Ñ' => 'n',
            c => c.to_ascii_lowercase(),
        })
        .collect()
}

const WEEKDAYS: [(&str, Weekday, &str); 7] = [
    ("lunes", Weekday::Mon, "MO"),
    ("martes", Weekday::Tue, "TU"),
    ("miercoles", Weekday::Wed, "WE"),
    ("jueves", Weekday::Thu, "TH"),
    ("viernes", Weekday::Fri, "FR"),
    ("sabado", Weekday::Sat, "SA"),
    ("domingo", Weekday::Sun, "SU"),
];

const MONTHS: [&str; 12] = [
    "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic",
];

static RE_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:^|\s)#([\p{L}\p{N}_\-]+)").unwrap());
static RE_PRIO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:^|\s)(!{1,3})(?:\s|$)").unwrap());
static RE_REPEAT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:cada|todos los|todas las)\s+(?:(\d+)\s+)?(dia laborable|dias laborables|dias|dia|semanas|semana|meses|mes|anos|ano|lunes|martes|miercoles|jueves|viernes|sabados|sabado|domingos|domingo)\b").unwrap()
});
static RE_WORKDAYS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(?:entre semana|de lunes a viernes)\b").unwrap());
static RE_RELDAY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(pasado manana|manana|hoy)\b").unwrap());
static RE_IN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:en|dentro de)\s+(\d+|un|una|dos|tres)\s+(dias|dia|semanas|semana|meses|mes)\b").unwrap()
});
static RE_WEEKDAY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:(?:el|este|esta|el proximo|el siguiente)\s+)?(lunes|martes|miercoles|jueves|viernes|sabado|domingo)(?:\s+(?:que viene|proximo))?\b").unwrap()
});
static RE_DATE_TEXT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:el\s+)?(\d{1,2})\s+(?:de\s+)?(ene|feb|mar|abr|may|jun|jul|ago|sep|oct|nov|dic)[a-z]*\.?(?:\s+(?:de\s+)?(\d{4}))?\b").unwrap()
});
static RE_DATE_NUM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:el\s+)?(\d{1,2})[/\-](\d{1,2})(?:[/\-](\d{2,4}))?\b").unwrap()
});
static RE_TIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:a\s+las?\s+|a\s+la\s+|sobre\s+las?\s+)?(\d{1,2})(?:[:\.](\d{2}))?(?:\s*(h\b|hs\b|horas\b|am\b|pm\b))?(?:\s+de\s+la\s+(manana|tarde|noche|madrugada))?").unwrap()
});
static RE_NOON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(?:a\s+)?(?:mediodia|medio dia)\b").unwrap());
static RE_DURATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:durante|por)\s+(\d+)\s*(h|horas?|min|minutos?)\b").unwrap()
});

fn num_word(s: &str) -> i64 {
    match s {
        "un" | "una" => 1,
        "dos" => 2,
        "tres" => 3,
        n => n.parse().unwrap_or(1),
    }
}

fn next_weekday(from: NaiveDate, wd: Weekday) -> NaiveDate {
    let mut d = from + Duration::days(1);
    while d.weekday() != wd {
        d += Duration::days(1);
    }
    d
}

/// Elimina de `orig` el tramo [a, b) medido sobre la versión sin acentos (misma longitud en caracteres).
fn cut(orig: &mut Vec<char>, norm: &mut Vec<char>, a: usize, b: usize) {
    for i in a..b.min(orig.len()) {
        orig[i] = '\u{0}';
        norm[i] = '\u{0}';
    }
}

fn byte_to_char(s: &str, byte: usize) -> usize {
    s[..byte].chars().count()
}

pub fn parse(input: &str, now: NaiveDateTime) -> Quick {
    let mut q = Quick { duration_min: 60, ..Default::default() };
    let mut orig: Vec<char> = input.chars().collect();
    let mut norm: Vec<char> = strip_accents(input).chars().collect();
    let today = now.date();
    let mut date: Option<NaiveDate> = None;
    let mut tm: Option<NaiveTime> = None;

    // Ejecuta una regex sobre el texto normalizado restante y elimina la coincidencia.
    let mut take = |re: &Regex, orig: &mut Vec<char>, norm: &mut Vec<char>| -> Option<Vec<Option<String>>> {
        let n: String = norm.iter().map(|c| if *c == '\u{0}' { ' ' } else { *c }).collect();
        let caps = re.captures(&n)?;
        let m = caps.get(0)?;
        let groups = (1..caps.len()).map(|i| caps.get(i).map(|g| g.as_str().to_string())).collect();
        let (a, b) = (byte_to_char(&n, m.start()), byte_to_char(&n, m.end()));
        cut(orig, norm, a, b);
        Some(groups)
    };

    // Etiquetas (sobre el original para conservar mayúsculas y acentos, normalizadas en minúsculas).
    {
        let o: String = orig.iter().collect();
        for c in RE_TAG.captures_iter(&o) {
            q.tags.push(format!("#{}", c[1].to_lowercase()));
        }
        let mut ranges = vec![];
        for m in RE_TAG.find_iter(&o) {
            ranges.push((byte_to_char(&o, m.start()), byte_to_char(&o, m.end())));
        }
        for (a, b) in ranges {
            cut(&mut orig, &mut norm, a, b);
        }
    }
    if let Some(g) = take(&RE_PRIO, &mut orig, &mut norm) {
        q.priority = g[0].as_ref().map(|s| s.len() as i64).unwrap_or(0);
    }
    if let Some(g) = take(&RE_DURATION, &mut orig, &mut norm) {
        let n: i64 = g[0].as_deref().unwrap_or("1").parse().unwrap_or(1);
        q.duration_min = if g[1].as_deref().unwrap_or("h").starts_with('h') { n * 60 } else { n };
    }
    // Recurrencias.
    if take(&RE_WORKDAYS, &mut orig, &mut norm).is_some() {
        q.rrule = Some("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR".into());
    } else if let Some(g) = take(&RE_REPEAT, &mut orig, &mut norm) {
        let n: i64 = g[0].as_deref().map(|s| s.parse().unwrap_or(1)).unwrap_or(1);
        let unit = g[1].clone().unwrap_or_default();
        let interval = if n > 1 { format!(";INTERVAL={n}") } else { String::new() };
        let rule = if unit.contains("laborable") {
            "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR".to_string()
        } else if unit.starts_with("dia") {
            format!("FREQ=DAILY{interval}")
        } else if unit.starts_with("semana") {
            format!("FREQ=WEEKLY{interval}")
        } else if unit.starts_with("mes") {
            format!("FREQ=MONTHLY{interval}")
        } else if unit.starts_with("ano") {
            format!("FREQ=YEARLY{interval}")
        } else {
            let base = unit.trim_end_matches('s');
            let (_, wd, code) = WEEKDAYS.iter().find(|(n, _, _)| *n == base || n.trim_end_matches('s') == base).unwrap();
            if date.is_none() {
                date = Some(if today.weekday() == *wd { today } else { next_weekday(today, *wd) });
            }
            format!("FREQ=WEEKLY{interval};BYDAY={code}")
        };
        q.rrule = Some(rule);
    }
    // Fechas.
    if let Some(g) = take(&RE_RELDAY, &mut orig, &mut norm) {
        date = Some(match g[0].as_deref() {
            Some("hoy") => today,
            Some("manana") => today + Duration::days(1),
            _ => today + Duration::days(2),
        });
    } else if let Some(g) = take(&RE_IN, &mut orig, &mut norm) {
        let n = num_word(g[0].as_deref().unwrap_or("1"));
        let unit = g[1].clone().unwrap_or_default();
        date = Some(if unit.starts_with("dia") {
            today + Duration::days(n)
        } else if unit.starts_with("semana") {
            today + Duration::weeks(n)
        } else {
            today.checked_add_months(chrono::Months::new(n as u32)).unwrap_or(today)
        });
    } else if let Some(g) = take(&RE_DATE_TEXT, &mut orig, &mut norm) {
        let d: u32 = g[0].as_deref().unwrap_or("1").parse().unwrap_or(1);
        let m = MONTHS.iter().position(|x| Some(*x) == g[1].as_deref()).unwrap_or(0) as u32 + 1;
        let explicit_year = g[2].as_deref().and_then(|y| y.parse::<i32>().ok());
        let mut y = explicit_year.unwrap_or(today.year());
        let mut cand = NaiveDate::from_ymd_opt(y, m, d);
        if explicit_year.is_none() && cand.map(|c| c < today).unwrap_or(false) {
            y += 1;
            cand = NaiveDate::from_ymd_opt(y, m, d);
        }
        date = cand;
    } else if let Some(g) = take(&RE_DATE_NUM, &mut orig, &mut norm) {
        let d: u32 = g[0].as_deref().unwrap_or("1").parse().unwrap_or(1);
        let m: u32 = g[1].as_deref().unwrap_or("1").parse().unwrap_or(1);
        let explicit_year = g[2].as_deref().and_then(|y| y.parse::<i32>().ok()).map(|y| if y < 100 { 2000 + y } else { y });
        let mut cand = NaiveDate::from_ymd_opt(explicit_year.unwrap_or(today.year()), m, d);
        if explicit_year.is_none() && cand.map(|c| c < today).unwrap_or(false) {
            cand = NaiveDate::from_ymd_opt(today.year() + 1, m, d);
        }
        date = cand.or(date);
    } else if let Some(g) = take(&RE_WEEKDAY, &mut orig, &mut norm) {
        let name = g[0].clone().unwrap_or_default();
        if let Some((_, wd, _)) = WEEKDAYS.iter().find(|(n, _, _)| *n == name) {
            date = Some(next_weekday(today, *wd));
        }
    }
    // Hora.
    if take(&RE_NOON, &mut orig, &mut norm).is_some() {
        tm = NaiveTime::from_hms_opt(12, 0, 0);
    } else {
        // Solo se acepta una hora si va precedida de «a las», lleva minutos o un sufijo (h, am, pm).
        let n: String = norm.iter().map(|c| if *c == '\u{0}' { ' ' } else { *c }).collect();
        for caps in RE_TIME.captures_iter(&n) {
            let full = caps.get(0).unwrap();
            let txt = full.as_str();
            let explicit = txt.trim_start().starts_with('a') || txt.trim_start().starts_with("sobre")
                || caps.get(2).is_some() || caps.get(3).is_some() || caps.get(4).is_some();
            if !explicit {
                continue;
            }
            let mut h: u32 = caps[1].parse().unwrap_or(0);
            let mi: u32 = caps.get(2).map(|m| m.as_str().parse().unwrap_or(0)).unwrap_or(0);
            let suf = caps.get(3).map(|m| m.as_str()).unwrap_or("");
            let part = caps.get(4).map(|m| m.as_str()).unwrap_or("");
            if (suf == "pm" || part == "tarde" || part == "noche") && h < 12 {
                h += 12;
            }
            if (suf == "am" || part == "madrugada" || part == "manana") && h == 12 {
                h = 0;
            }
            if h < 24 && mi < 60 {
                tm = NaiveTime::from_hms_opt(h, mi, 0);
                let (a, b) = (byte_to_char(&n, full.start()), byte_to_char(&n, full.end()));
                cut(&mut orig, &mut norm, a, b);
                break;
            }
        }
    }
    if tm.is_some() && date.is_none() {
        // Solo hora: hoy si aún no ha pasado, si no, mañana.
        let t = tm.unwrap();
        date = Some(if today.and_time(t) > now { today } else { today + Duration::days(1) });
    }
    if let Some(d) = date {
        match tm {
            Some(t) => {
                q.date = Some(d.and_time(t).format("%Y-%m-%dT%H:%M:%S").to_string());
                q.has_time = true;
            }
            None => q.date = Some(d.format("%Y-%m-%d").to_string()),
        }
    }
    // Título: lo que queda, sin conectores colgando.
    let rest: String = orig.iter().filter(|c| **c != '\u{0}').collect();
    let mut words: Vec<&str> = rest.split_whitespace().collect();
    let dangling = ["el", "la", "a", "las", "de", "del", "en", "para", "y", "este", "esta", "cada"];
    while words.last().map(|w| dangling.contains(&strip_accents(w).as_str())).unwrap_or(false) {
        words.pop();
    }
    while words.first().map(|w| ["el", "a", "de"].contains(&strip_accents(w).as_str())).unwrap_or(false) && words.len() > 1 {
        words.remove(0);
    }
    q.title = words.join(" ");
    if q.title.is_empty() {
        q.title = input.trim().to_string();
    }
    q
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> NaiveDateTime {
        // Martes 3 de noviembre de 2026, 9:41
        NaiveDate::from_ymd_opt(2026, 11, 3).unwrap().and_hms_opt(9, 41, 0).unwrap()
    }

    #[test]
    fn dinner_friday() {
        let q = parse("Cena con Ana el viernes a las 21h #Amigos", now());
        assert_eq!(q.title, "Cena con Ana");
        assert_eq!(q.date.as_deref(), Some("2026-11-06T21:00:00"));
        assert_eq!(q.tags, vec!["#amigos"]);
    }

    #[test]
    fn tomorrow_priority() {
        let q = parse("Pagar recibo IBI mañana !!", now());
        assert_eq!(q.title, "Pagar recibo IBI");
        assert_eq!(q.date.as_deref(), Some("2026-11-04"));
        assert!(!q.has_time);
        assert_eq!(q.priority, 2);
    }

    #[test]
    fn recurring_workdays() {
        let q = parse("Daily cada día laborable a las 9:30", now());
        assert_eq!(q.title, "Daily");
        assert_eq!(q.rrule.as_deref(), Some("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"));
        assert_eq!(q.date.as_deref(), Some("2026-11-04T09:30:00"));
    }

    #[test]
    fn text_date_and_pm() {
        let q = parse("Dentista el 12 de noviembre a las 5 de la tarde", now());
        assert_eq!(q.title, "Dentista");
        assert_eq!(q.date.as_deref(), Some("2026-11-12T17:00:00"));
        let q = parse("Renovar DNI 15/1", now());
        assert_eq!(q.date.as_deref(), Some("2027-01-15"));
    }

    #[test]
    fn every_two_weeks_on_tuesday() {
        let q = parse("Slides del sprint cada 2 semanas", now());
        assert_eq!(q.rrule.as_deref(), Some("FREQ=WEEKLY;INTERVAL=2"));
        let q = parse("Yoga cada miércoles 19:00", now());
        assert_eq!(q.rrule.as_deref(), Some("FREQ=WEEKLY;BYDAY=WE"));
        assert_eq!(q.date.as_deref(), Some("2026-11-04T19:00:00"));
        assert_eq!(q.title, "Yoga");
    }

    #[test]
    fn plain_numbers_are_not_times() {
        let q = parse("Comprar 3 cartuchos", now());
        assert_eq!(q.title, "Comprar 3 cartuchos");
        assert!(q.date.is_none());
        let q = parse("Revisar PR 142 en 2 días durante 30 min", now());
        assert_eq!(q.title, "Revisar PR 142");
        assert_eq!(q.date.as_deref(), Some("2026-11-05"));
        assert_eq!(q.duration_min, 30);
    }
}
