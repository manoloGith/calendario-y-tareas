//! Prueba contra un servidor CalDAV real. Se ejecuta si existe CALDAV_TEST_URL, por ejemplo con Radicale:
//!   python3 -m radicale --server-hosts 127.0.0.1:5232 --auth-type none
//!   CALDAV_TEST_URL=http://127.0.0.1:5232/ cargo test --test caldav
use calendario_core::model::*;
use calendario_core::vault::{self, TaskFilter, Vault};
use std::path::PathBuf;

fn tmp(name: &str) -> PathBuf {
    std::env::set_var("CALENDARIO_TZ", "Europe/Madrid");
    let d = std::env::temp_dir().join(format!("cal-dav-{}-{}", name, uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&d).unwrap();
    d.join("v.db")
}

const PW: &str = "contraseña-larga";

#[test]
fn two_devices_offline_first_sync() {
    let Ok(base) = std::env::var("CALDAV_TEST_URL") else {
        eprintln!("CALDAV_TEST_URL no definida: prueba omitida");
        return;
    };
    let user = format!("u{}", &uuid::Uuid::new_v4().to_string()[..8]);
    let url = format!("{}{}/", base.trim_end_matches('/').to_string() + "/", user);

    // Dispositivo A: alta de cuenta y calendario remoto nuevo.
    let pa = tmp("a");
    let a = Vault::create(&pa, PW).unwrap();
    let (acc, _) = a.add_caldav("Radicale", &url, &user, "x").unwrap();
    let cal = a.create_remote_calendar(&acc.id, "Proyectos", "#AF52DE", "both").unwrap();
    let ev = a.quick_event("Taller de cifrado el miércoles a las 11:00", &cal.id).unwrap();
    let parent = a.quick_task("Revisar PR 142 mañana #revisión !!", &cal.id, None).unwrap();
    a.quick_task("Probar archivos grandes", &cal.id, Some(parent.id.clone())).unwrap();
    assert_eq!(a.db.pending_changes().unwrap(), 3, "los cambios esperan en local hasta sincronizar");
    let r = vault::sync_accounts(&pa, PW, None).unwrap();
    let st = r[0].1.as_ref().unwrap();
    assert_eq!(st.uploaded, 3, "{st:?}");
    assert_eq!(a.db.pending_changes().unwrap(), 0);

    // Dispositivo B: misma cuenta, descarga todo.
    let pb = tmp("b");
    let b = Vault::create(&pb, PW).unwrap();
    b.add_caldav("Radicale", &url, &user, "x").unwrap();
    vault::sync_accounts(&pb, PW, None).unwrap();
    let bcal = b.db.calendars().unwrap().into_iter().find(|c| c.name == "Proyectos").unwrap();
    assert_eq!(b.db.events_in_calendar(&bcal.id).unwrap().len(), 1);
    let bt = b.tasks(&TaskFilter { list_id: Some(bcal.id.clone()), ..Default::default() }).unwrap();
    assert_eq!(bt.len(), 1);
    assert_eq!(bt[0].sub_total, 1);
    assert_eq!(bt[0].task.tags, vec!["#revisión"]);

    // Ambos trabajan «sin conexión»: A edita el evento, B completa la tarea y borra la subtarea.
    let mut e2 = a.db.event(&ev.id).unwrap();
    e2.title = "Taller de cifrado (sala Ada)".into();
    a.save_event(e2, "all", None).unwrap();
    b.toggle_task(&parent.id).unwrap();
    let sub_b = b.db.children(&parent.id).unwrap()[0].id.clone();
    b.delete_task(&sub_b).unwrap();
    // Al reconectar, cada uno sube lo suyo y recibe lo del otro.
    vault::sync_accounts(&pb, PW, None).unwrap();
    vault::sync_accounts(&pa, PW, None).unwrap();
    vault::sync_accounts(&pb, PW, None).unwrap();
    assert_eq!(b.db.event(&ev.id).unwrap().title, "Taller de cifrado (sala Ada)");
    assert!(a.db.task(&parent.id).unwrap().completed);
    assert!(a.db.children(&parent.id).unwrap().is_empty());

    // Conflicto: ambos editan el mismo evento; gana la edición más reciente.
    let mut ea = a.db.event(&ev.id).unwrap();
    ea.location = "Sala Ada".into();
    a.save_event(ea, "all", None).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let mut eb = b.db.event(&ev.id).unwrap();
    eb.location = "Sala Turing".into();
    b.save_event(eb, "all", None).unwrap();
    vault::sync_accounts(&pa, PW, None).unwrap();
    let rb = vault::sync_accounts(&pb, PW, None).unwrap();
    assert_eq!(rb[0].1.as_ref().unwrap().conflicts, 1);
    vault::sync_accounts(&pa, PW, None).unwrap();
    assert_eq!(a.db.event(&ev.id).unwrap().location, "Sala Turing");

    // Sin red: el alta falla con un error de red y los datos locales siguen intactos.
    let err = a.add_caldav("Caído", "http://127.0.0.1:5999/", "x", "y").unwrap_err();
    assert!(err.to_string().contains("red"), "{err}");
    assert_eq!(a.db.events_in_calendar(&cal.id).unwrap().len(), 1);
}

#[test]
fn ignores_unknown_when_no_server() {
    // Siempre se ejecuta: comprobar que un evento CalDAV queda pendiente sin red.
    let p = tmp("off");
    let v = Vault::create(&p, PW).unwrap();
    let mut c = Calendar {
        id: String::new(),
        name: "Remoto".into(),
        color: "#000".into(),
        kind: "both".into(),
        source: SOURCE_CALDAV.into(),
        visible: true,
        position: 9,
        ics_path: None,
        account_id: None,
        remote_url: Some("http://127.0.0.1:5999/x/".into()),
        ctag: None,
        readonly: false,
    };
    v.db.save_calendar(&mut c).unwrap();
    v.quick_event("Algo mañana a las 10", &c.id).unwrap();
    assert_eq!(v.db.pending_changes().unwrap(), 1);
}
