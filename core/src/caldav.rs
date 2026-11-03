//! Conector CalDAV (RFC 4791). Local primero: los cambios se guardan en la base de datos y se marcan
//! como pendientes («dirty»); `sync_calendar` los sube cuando hay red y luego descarga lo nuevo del servidor.
use crate::db::Db;
use crate::error::{Error, Result};
use crate::ics;
use crate::model::*;
use quick_xml::events::Event as X;
use quick_xml::Reader;
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderValue, CONTENT_TYPE, LOCATION};
use reqwest::{Method, StatusCode, Url};
use serde::Serialize;
use std::collections::HashMap;
use std::time::Duration;

#[derive(Debug, Default, Clone)]
pub struct DavResponse {
    pub href: String,
    pub props: HashMap<String, String>,
    pub resource_types: Vec<String>,
    pub components: Vec<String>,
}

/// Analiza una respuesta `multistatus`, quedándose solo con las propiedades con estado 200.
pub fn parse_multistatus(xml: &str) -> Vec<DavResponse> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut out = vec![];
    let mut stack: Vec<String> = vec![];
    let mut cur: Option<DavResponse> = None;
    let mut pending = DavResponse::default();
    let mut status = String::new();
    loop {
        match reader.read_event() {
            Ok(X::Start(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                match name.as_str() {
                    "response" => cur = Some(DavResponse::default()),
                    "propstat" => {
                        pending = DavResponse::default();
                        status.clear();
                    }
                    _ => {}
                }
                if stack.last().map(|s| s == "resourcetype").unwrap_or(false) {
                    pending.resource_types.push(name.clone());
                }
                stack.push(name);
            }
            Ok(X::Empty(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                let parent = stack.last().cloned().unwrap_or_default();
                if parent == "resourcetype" {
                    pending.resource_types.push(name);
                } else if name == "comp" && parent == "supported-calendar-component-set" {
                    for a in e.attributes().flatten() {
                        if a.key.local_name().as_ref() == b"name" {
                            if let Ok(v) = a.unescape_value() {
                                pending.components.push(v.to_ascii_uppercase());
                            }
                        }
                    }
                }
            }
            Ok(X::End(_)) => {
                let name = stack.pop().unwrap_or_default();
                match name.as_str() {
                    "propstat" => {
                        if status.contains(" 200") || status.is_empty() {
                            if let Some(c) = cur.as_mut() {
                                c.props.extend(pending.props.drain());
                                c.resource_types.append(&mut pending.resource_types);
                                c.components.append(&mut pending.components);
                            }
                        }
                    }
                    "response" => {
                        if let Some(c) = cur.take() {
                            out.push(c);
                        }
                    }
                    _ => {}
                }
            }
            Ok(X::Text(t)) => {
                let txt = t.unescape().map(|c| c.to_string()).unwrap_or_default();
                handle_text(&stack, &txt, &mut cur, &mut pending, &mut status);
            }
            Ok(X::CData(c)) => {
                let txt = String::from_utf8_lossy(&c.into_inner()).to_string();
                handle_text(&stack, &txt, &mut cur, &mut pending, &mut status);
            }
            Ok(X::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

fn handle_text(stack: &[String], txt: &str, cur: &mut Option<DavResponse>, pending: &mut DavResponse, status: &mut String) {
    let leaf = stack.last().map(|s| s.as_str()).unwrap_or("");
    let parent = if stack.len() >= 2 { stack[stack.len() - 2].as_str() } else { "" };
    if leaf == "href" && parent == "response" {
        if let Some(c) = cur.as_mut() {
            c.href = txt.trim().to_string();
        }
    } else if leaf == "status" && parent == "propstat" {
        *status = txt.to_string();
    } else if leaf == "href" {
        // href anidado (current-user-principal, calendar-home-set…): se guarda con el nombre del padre.
        pending.props.entry(parent.to_string()).or_insert_with(|| txt.trim().to_string());
    } else if stack.iter().any(|s| s == "prop") {
        pending.props.entry(leaf.to_string()).or_default().push_str(txt);
    }
}

pub struct Dav {
    client: Client,
    user: String,
    pass: String,
}

pub struct Reply {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: String,
    pub url: Url,
}

impl Dav {
    pub fn new(user: &str, pass: &str) -> Result<Dav> {
        Self::with_timeout(user, pass, Duration::from_secs(30))
    }

    /// Cliente con tiempo de espera corto para comprobar si una dirección responde.
    pub fn quick(user: &str, pass: &str) -> Result<Dav> {
        Self::with_timeout(user, pass, crate::endpoints::PROBE_TIMEOUT)
    }

    fn with_timeout(user: &str, pass: &str, timeout: Duration) -> Result<Dav> {
        let client = Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout.min(Duration::from_secs(5)))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("CalendarioYTareas/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| Error::Net(e.to_string()))?;
        Ok(Dav { client, user: user.into(), pass: pass.into() })
    }

    pub fn request(&self, method: &str, url: &Url, depth: Option<&str>, body: Option<String>, hdrs: &[(&str, String)]) -> Result<Reply> {
        let mut url = url.clone();
        for _ in 0..5 {
            let mut rq = self
                .client
                .request(Method::from_bytes(method.as_bytes()).unwrap(), url.clone())
                .basic_auth(&self.user, Some(&self.pass));
            if let Some(d) = depth {
                rq = rq.header("Depth", d);
            }
            for (k, v) in hdrs {
                rq = rq.header(*k, v.as_str());
            }
            if let Some(b) = &body {
                let ct = if method == "PUT" { "text/calendar; charset=utf-8" } else { "application/xml; charset=utf-8" };
                rq = rq.header(CONTENT_TYPE, ct).body(b.clone());
            }
            let resp = rq.send().map_err(|e| Error::Net(e.to_string()))?;
            let status = resp.status();
            if status.is_redirection() {
                if let Some(loc) = resp.headers().get(LOCATION).and_then(|l| l.to_str().ok()) {
                    url = url.join(loc).map_err(|e| Error::Net(e.to_string()))?;
                    continue;
                }
            }
            let headers = resp.headers().clone();
            let final_url = resp.url().clone();
            let body = resp.text().unwrap_or_default();
            if status == StatusCode::UNAUTHORIZED {
                return Err(Error::CalDav("usuario o contraseña incorrectos".into()));
            }
            return Ok(Reply { status, headers, body, url: final_url });
        }
        Err(Error::CalDav("demasiadas redirecciones".into()))
    }

    fn propfind(&self, url: &Url, depth: &str, props: &str) -> Result<(Url, Vec<DavResponse>)> {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/"><d:prop>{props}</d:prop></d:propfind>"#
        );
        let r = self.request("PROPFIND", url, Some(depth), Some(body), &[])?;
        if r.status.as_u16() != 207 {
            return Err(Error::CalDav(format!("PROPFIND {} devolvió {}", url, r.status)));
        }
        Ok((r.url, parse_multistatus(&r.body)))
    }
}

fn join(base: &Url, href: &str) -> Result<Url> {
    base.join(href).map_err(|e| Error::CalDav(format!("URL no válida {href}: {e}")))
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct RemoteCalendar {
    pub url: String,
    pub name: String,
    pub color: Option<String>,
    pub kind: String,
    pub ctag: Option<String>,
}

/// Descubre el principal, el «calendar-home-set» y las colecciones de calendario de una cuenta.
pub fn discover(dav: &Dav, base_url: &str) -> Result<(String, String, Vec<RemoteCalendar>)> {
    let base = Url::parse(base_url.trim()).map_err(|e| Error::Invalid(format!("URL no válida: {e}")))?;
    let props = "<d:current-user-principal/><c:calendar-home-set/><d:resourcetype/>";
    let attempt = dav.propfind(&base, "0", props).or_else(|_| {
        let wk = join(&base, "/.well-known/caldav")?;
        dav.propfind(&wk, "0", props)
    })?;
    let (found_url, resp) = attempt;
    let first = resp.first().cloned().unwrap_or_default();
    // Si la URL ya es una colección de calendario, se usa directamente.
    if first.resource_types.iter().any(|r| r == "calendar") {
        let cals = list_collections(dav, &found_url, "0")?;
        return Ok((found_url.to_string(), found_url.to_string(), cals));
    }
    let principal = match first.props.get("current-user-principal") {
        Some(p) => join(&found_url, p)?,
        None => found_url.clone(),
    };
    let home = match first.props.get("calendar-home-set") {
        Some(h) => join(&found_url, h)?,
        None => {
            let (u, r) = dav.propfind(&principal, "0", "<c:calendar-home-set/>")?;
            let h = r
                .first()
                .and_then(|x| x.props.get("calendar-home-set"))
                .ok_or_else(|| Error::CalDav("el servidor no indica dónde están los calendarios".into()))?;
            join(&u, h)?
        }
    };
    let cals = list_collections(dav, &home, "1")?;
    Ok((principal.to_string(), home.to_string(), cals))
}

fn list_collections(dav: &Dav, home: &Url, depth: &str) -> Result<Vec<RemoteCalendar>> {
    let (u, resp) = dav.propfind(
        home,
        depth,
        "<d:displayname/><d:resourcetype/><c:supported-calendar-component-set/><a:calendar-color/><cs:getctag/>",
    )?;
    let mut out = vec![];
    for r in resp {
        if !r.resource_types.iter().any(|t| t == "calendar") {
            continue;
        }
        let url = join(&u, &r.href)?;
        let comps = &r.components;
        let ev = comps.is_empty() || comps.iter().any(|c| c == "VEVENT");
        let td = comps.is_empty() || comps.iter().any(|c| c == "VTODO");
        let kind = match (ev, td) {
            (true, true) => "both",
            (false, true) => "tasks",
            _ => "events",
        };
        let name = r
            .props
            .get("displayname")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| url.path_segments().and_then(|s| s.filter(|x| !x.is_empty()).last()).unwrap_or("Calendario").to_string());
        let color = r.props.get("calendar-color").map(|c| c.trim().chars().take(7).collect::<String>()).filter(|c| c.starts_with('#'));
        out.push(RemoteCalendar { url: url.to_string(), name, color, kind: kind.into(), ctag: r.props.get("getctag").cloned() });
    }
    Ok(out)
}

/// Crea una colección nueva en el servidor (MKCALENDAR).
pub fn make_calendar(dav: &Dav, home_url: &str, name: &str, color: &str, kind: &str) -> Result<String> {
    let home = Url::parse(home_url).map_err(|e| Error::Invalid(e.to_string()))?;
    let slug = uuid::Uuid::new_v4().to_string();
    let url = join(&home, &format!("{slug}/"))?;
    let comps = match kind {
        "events" => r#"<c:comp name="VEVENT"/>"#.to_string(),
        "tasks" => r#"<c:comp name="VTODO"/>"#.to_string(),
        _ => r#"<c:comp name="VEVENT"/><c:comp name="VTODO"/>"#.to_string(),
    };
    let body = format!(
        r#"<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop><d:displayname>{}</d:displayname><a:calendar-color>{}</a:calendar-color><c:supported-calendar-component-set>{comps}</c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"#,
        xml_escape(name),
        xml_escape(color)
    );
    let r = dav.request("MKCALENDAR", &url, None, Some(body), &[])?;
    if !r.status.is_success() {
        return Err(Error::CalDav(format!("no se pudo crear el calendario ({})", r.status)));
    }
    Ok(url.to_string())
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

#[derive(Debug, Default, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SyncStats {
    pub uploaded: usize,
    pub deleted_remote: usize,
    pub downloaded: usize,
    pub deleted_local: usize,
    pub conflicts: usize,
}

fn etag_of(h: &HeaderMap) -> Option<String> {
    h.get("etag").and_then(|v: &HeaderValue| v.to_str().ok()).map(|s| s.to_string())
}

fn resource_name(id: &str) -> String {
    let safe: String = id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' { c } else { '_' }).collect();
    format!("{safe}.ics")
}

fn apply_remote(db: &Db, cal: &Calendar, href: &str, etag: Option<&str>, data: &str) -> Result<usize> {
    let parsed = ics::read(data, &crate::time::system_tzid());
    let mut n = 0;
    for mut e in parsed.events {
        e.calendar_id = cal.id.clone();
        let detached = e.id.contains("::");
        if e.updated.is_empty() || !e.updated.contains('-') {
            e.updated = crate::time::now_utc_string();
        }
        db.save_event(&mut e, false)?;
        // Las ocurrencias modificadas comparten recurso con el maestro: se marcan con un fragmento y no se suben por separado.
        let h = if detached { format!("{href}#{}", e.id) } else { href.to_string() };
        db.set_remote("events", &e.id, &h, etag)?;
        n += 1;
    }
    let (roots, subs): (Vec<Task>, Vec<Task>) = parsed.tasks.into_iter().partition(|t| t.parent_id.is_none());
    for mut t in roots.into_iter().chain(subs) {
        t.list_id = cal.id.clone();
        if t.updated.is_empty() || !t.updated.contains('-') {
            t.updated = crate::time::now_utc_string();
        }
        db.save_task(&mut t, false)?;
        db.set_remote("tasks", &t.id, href, etag)?;
        n += 1;
    }
    Ok(n)
}

/// Sincroniza un calendario: sube los cambios pendientes y descarga los del servidor.
pub fn sync_calendar(db: &Db, dav: &Dav, cal: &Calendar) -> Result<SyncStats> {
    let mut st = SyncStats::default();
    let base = Url::parse(cal.remote_url.as_deref().ok_or_else(|| Error::CalDav("calendario sin URL".into()))?)
        .map_err(|e| Error::CalDav(e.to_string()))?;

    // 1) Subida de cambios locales.
    for table in ["events", "tasks"] {
        for m in db.remote_meta(table, &cal.id)?.into_iter().filter(|m| m.dirty) {
            if m.href.as_deref().map(|h| h.contains('#')).unwrap_or(false) {
                continue; // ocurrencia separada: solo local
            }
            if m.deleted {
                if let Some(h) = &m.href {
                    let url = join(&base, h)?;
                    let hdr: Vec<(&str, String)> = m.etag.iter().map(|e| ("If-Match", e.clone())).collect();
                    let r = dav.request("DELETE", &url, None, None, &hdr)?;
                    if r.status.is_success() || r.status == StatusCode::NOT_FOUND {
                        st.deleted_remote += 1;
                    } else if r.status == StatusCode::PRECONDITION_FAILED {
                        st.conflicts += 1; // cambió en el servidor: se conserva la versión remota
                    }
                }
                if table == "events" { db.purge_event(&m.id)? } else { db.purge_task(&m.id)? }
                continue;
            }
            let body = if table == "events" { ics::single_event(&db.event(&m.id)?) } else { ics::single_task(&db.task(&m.id)?) };
            let href = m.href.clone().unwrap_or_else(|| join(&base, &resource_name(&m.id)).map(|u| u.path().to_string()).unwrap_or_default());
            let url = join(&base, &href)?;
            let pre: Vec<(&str, String)> = match &m.etag {
                Some(e) => vec![("If-Match", e.clone())],
                None if m.href.is_some() => vec![],
                None => vec![("If-None-Match", "*".to_string())],
            };
            let mut r = dav.request("PUT", &url, None, Some(body.clone()), &pre)?;
            if r.status == StatusCode::PRECONDITION_FAILED {
                st.conflicts += 1;
                // Conflicto: gana la versión más reciente (LAST-MODIFIED frente a la edición local).
                let g = dav.request("GET", &url, None, None, &[])?;
                let remote = ics::read(&g.body, &crate::time::system_tzid());
                let remote_updated = remote
                    .events
                    .first()
                    .map(|e| e.updated.clone())
                    .or_else(|| remote.tasks.first().map(|t| t.updated.clone()))
                    .unwrap_or_default();
                let remote_norm: String = remote_updated.chars().filter(|c| c.is_ascii_digit()).collect();
                let local_norm: String = m.updated.chars().filter(|c| c.is_ascii_digit()).collect();
                if g.status.is_success() && remote_norm > local_norm {
                    apply_remote(db, cal, &href, etag_of(&g.headers).as_deref(), &g.body)?;
                    continue;
                }
                r = dav.request("PUT", &url, None, Some(body), &[])?;
            }
            if !r.status.is_success() {
                return Err(Error::CalDav(format!("el servidor rechazó un cambio ({})", r.status)));
            }
            db.set_remote(table, &m.id, url.path(), etag_of(&r.headers).as_deref())?;
            st.uploaded += 1;
        }
    }

    // 2) Descarga: lista de recursos y sus ETag.
    let q = r#"<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop><c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>"#;
    let r = dav.request("REPORT", &base, Some("1"), Some(q.to_string()), &[])?;
    if r.status.as_u16() != 207 {
        return Err(Error::CalDav(format!("REPORT devolvió {}", r.status)));
    }
    let remote: HashMap<String, Option<String>> = parse_multistatus(&r.body)
        .into_iter()
        .filter(|x| !x.href.ends_with('/'))
        .map(|x| {
            let path = join(&base, &x.href).map(|u| u.path().to_string()).unwrap_or(x.href.clone());
            (path, x.props.get("getetag").cloned())
        })
        .collect();
    let mut local: HashMap<String, (Option<String>, bool)> = HashMap::new();
    let mut to_delete: Vec<(&str, String)> = vec![];
    for table in ["events", "tasks"] {
        for m in db.remote_meta(table, &cal.id)? {
            let Some(h) = m.href.clone() else { continue };
            let base_href = h.split('#').next().unwrap_or("").to_string();
            if !remote.contains_key(&base_href) {
                if !m.dirty {
                    to_delete.push((table, m.id.clone()));
                }
                continue;
            }
            let e = local.entry(base_href).or_insert((m.etag.clone(), false));
            e.1 |= m.dirty;
        }
    }
    for (table, id) in to_delete {
        if table == "events" { db.purge_event(&id)? } else { db.purge_task(&id)? }
        st.deleted_local += 1;
    }
    let fetch: Vec<String> = remote
        .iter()
        .filter(|(h, etag)| match local.get(*h) {
            None => true,
            Some((le, dirty)) => !dirty && (le.is_none() || le != *etag),
        })
        .map(|(h, _)| h.clone())
        .collect();
    for chunk in fetch.chunks(50) {
        let hrefs: String = chunk.iter().map(|h| format!("<d:href>{}</d:href>", xml_escape(h))).collect();
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>{hrefs}</c:calendar-multiget>"#
        );
        let r = dav.request("REPORT", &base, Some("1"), Some(body), &[])?;
        for x in parse_multistatus(&r.body) {
            let Some(data) = x.props.get("calendar-data") else { continue };
            let path = join(&base, &x.href).map(|u| u.path().to_string()).unwrap_or(x.href.clone());
            st.downloaded += apply_remote(db, cal, &path, x.props.get("getetag").map(|s| s.as_str()), data)?;
        }
    }
    Ok(st)
}

pub fn ctag(dav: &Dav, url: &str) -> Option<String> {
    let u = Url::parse(url).ok()?;
    let (_, r) = dav.propfind(&u, "0", "<cs:getctag/><d:sync-token/>").ok()?;
    let p = &r.first()?.props;
    p.get("getctag").or(p.get("sync-token")).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multistatus() {
        let xml = r#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
<d:response><d:href>/u/cal/</d:href><d:propstat><d:prop><d:displayname>Trabajo</d:displayname>
<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><x:missing xmlns:x="X"/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
<d:response><d:href>/u/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/p/u/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"#;
        let r = parse_multistatus(xml);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].props.get("displayname").map(|s| s.as_str()), Some("Trabajo"));
        assert!(r[0].resource_types.contains(&"calendar".to_string()));
        assert_eq!(r[0].components, vec!["VEVENT", "VTODO"]);
        assert!(!r[0].props.contains_key("missing"));
        assert_eq!(r[1].props.get("current-user-principal").map(|s| s.as_str()), Some("/p/u/"));
    }
}

/// Comprueba que la dirección responde como servidor WebDAV/CalDAV (y que las credenciales valen).
pub fn check(dav: &Dav, url: &str) -> Result<()> {
    let u = Url::parse(url).map_err(|e| Error::Invalid(e.to_string()))?;
    let r = dav.request(
        "PROPFIND",
        &u,
        Some("0"),
        Some(r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.into()),
        &[],
    )?;
    if r.status.as_u16() == 207 || r.status.is_success() {
        Ok(())
    } else {
        Err(Error::CalDav(format!("respuesta inesperada ({})", r.status)))
    }
}
