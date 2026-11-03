//! Conectividad con varias direcciones para un mismo servidor (p. ej. IP local y VPN/Tailscale).
//!
//! Es genérico: lo usa el conector CalDAV y lo usará el futuro servidor zero-knowledge. Las rutas
//! guardadas en la base de datos son independientes del origen (solo la ruta), así que cambiar de
//! dirección no obliga a volver a descargar nada.
use crate::error::{Error, Result};
use reqwest::Url;
use serde::Serialize;
use std::time::{Duration, Instant};

/// Tiempo máximo para comprobar si una dirección responde.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Normaliza y valida una lista de direcciones: quita vacías y repetidas, añade «https://» si falta
/// y la barra final.
pub fn normalize(urls: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = vec![];
    for u in urls {
        let u = u.trim();
        if u.is_empty() {
            continue;
        }
        let with_scheme = if u.contains("://") { u.to_string() } else { format!("https://{u}") };
        let mut parsed = Url::parse(&with_scheme).map_err(|e| Error::Invalid(format!("dirección no válida «{u}»: {e}")))?;
        if !parsed.path().ends_with('/') {
            let p = format!("{}/", parsed.path());
            parsed.set_path(&p);
        }
        let s = parsed.to_string();
        if !out.contains(&s) {
            out.push(s);
        }
    }
    if out.is_empty() {
        return Err(Error::Invalid("indica al menos una dirección".into()));
    }
    Ok(out)
}

/// Orden de prueba: primero la última que funcionó, luego el resto en el orden configurado.
pub fn order(urls: &[String], last_ok: Option<&str>) -> Vec<String> {
    let mut v: Vec<String> = vec![];
    if let Some(l) = last_ok {
        if urls.iter().any(|u| u == l) {
            v.push(l.to_string());
        }
    }
    for u in urls {
        if !v.contains(u) {
            v.push(u.clone());
        }
    }
    v
}

/// Cambia el origen (esquema, host y puerto) de `url` por el de `endpoint`, conservando la ruta.
/// Si la ruta guardada no empieza por la ruta base de la dirección original, se mantiene tal cual.
pub fn rebase(url: &str, endpoint: &str) -> Result<String> {
    let mut u = Url::parse(url).map_err(|e| Error::Invalid(e.to_string()))?;
    let e = Url::parse(endpoint).map_err(|e| Error::Invalid(e.to_string()))?;
    u.set_scheme(e.scheme()).map_err(|_| Error::Invalid("esquema no válido".into()))?;
    u.set_host(e.host_str()).map_err(|err| Error::Invalid(err.to_string()))?;
    u.set_port(e.port()).map_err(|_| Error::Invalid("puerto no válido".into()))?;
    Ok(u.to_string())
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Probe {
    pub url: String,
    pub ok: bool,
    pub ms: u64,
    pub error: Option<String>,
}

/// Prueba una dirección con `check` (que debe hacer una petición real) y mide el tiempo.
pub fn probe(url: &str, check: impl Fn(&str) -> Result<()>) -> Probe {
    let t = Instant::now();
    let r = check(url);
    Probe { url: url.to_string(), ok: r.is_ok(), ms: t.elapsed().as_millis() as u64, error: r.err().map(|e| e.to_string()) }
}

/// Devuelve la primera dirección que responde (en el orden de `order`), o un error de red con el detalle.
pub fn pick(urls: &[String], last_ok: Option<&str>, check: impl Fn(&str) -> Result<()>) -> Result<String> {
    let mut errors = vec![];
    for u in order(urls, last_ok) {
        let p = probe(&u, &check);
        if p.ok {
            return Ok(u);
        }
        errors.push(format!("{} ({})", host(&u), p.error.unwrap_or_default()));
    }
    Err(Error::Net(format!("ninguna dirección responde: {}", errors.join("; "))))
}

pub fn host(url: &str) -> String {
    Url::parse(url)
        .ok()
        .map(|u| format!("{}{}", u.host_str().unwrap_or(""), u.port().map(|p| format!(":{p}")).unwrap_or_default()))
        .unwrap_or_else(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_order_rebase() {
        let v = normalize(&["192.168.1.10:5232".into(), " ".into(), "https://nas.tail1234.ts.net/dav".into(), "192.168.1.10:5232".into()]).unwrap();
        assert_eq!(v, vec!["https://192.168.1.10:5232/", "https://nas.tail1234.ts.net/dav/"]);
        assert_eq!(order(&v, Some("https://nas.tail1234.ts.net/dav/"))[0], "https://nas.tail1234.ts.net/dav/");
        assert_eq!(order(&v, Some("https://otra/"))[0], "https://192.168.1.10:5232/");
        assert_eq!(
            rebase("http://192.168.1.10:5232/ana/trabajo/", "https://nas.tail1234.ts.net/").unwrap(),
            "https://nas.tail1234.ts.net/ana/trabajo/"
        );
        assert!(normalize(&[]).is_err());
    }

    #[test]
    fn pick_first_that_answers() {
        let urls = vec!["http://a/".to_string(), "http://b/".to_string()];
        let ok = pick(&urls, None, |u| if u.contains("b") { Ok(()) } else { Err(Error::Net("caído".into())) }).unwrap();
        assert_eq!(ok, "http://b/");
        let err = pick(&urls, None, |_| Err(Error::Net("caído".into()))).unwrap_err();
        assert!(err.to_string().contains("ninguna dirección"));
    }
}
