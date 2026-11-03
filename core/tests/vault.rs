use calendario_core::model::*;
use calendario_core::vault::{TaskFilter, Vault};
use calendario_core::{api, backup};
use serde_json::{json, Value};
use std::path::PathBuf;

fn tmp(name: &str) -> PathBuf {
    std::env::set_var("CALENDARIO_TZ", "Europe/Madrid");
    let d = std::env::temp_dir().join(format!("cal-test-{}-{}", name, uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn work_cal(v: &Vault) -> String {
    v.db.calendars().unwrap().into_iter().find(|c| c.name == "Trabajo").unwrap().id
}

#[test]
fn vault_is_encrypted_and_password_checked() {
    let d = tmp("enc");
    let p = d.join("datos.calendario");
    {
        let v = Vault::create(&p, "contraseña-larga").unwrap();
        assert_eq!(v.db.calendars().unwrap().len(), 2);
    }
    assert!(Vault::open(&p, "otra-contraseña").is_err());
    let raw = std::fs::read(&p).unwrap();
    assert!(!raw.starts_with(b"SQLite format 3"), "el archivo no debe ser SQLite en claro");
    assert!(!String::from_utf8_lossy(&raw).contains("Trabajo"));
    let mut v = Vault::open(&p, "contraseña-larga").unwrap();
    v.change_password("contraseña-larga", "nueva-contraseña").unwrap();
    drop(v);
    assert!(Vault::open(&p, "nueva-contraseña").is_ok());
}

#[test]
fn recurring_event_edit_this_and_future() {
    let d = tmp("rec");
    let v = Vault::create(&d.join("v.db"), "contraseña-larga").unwrap();
    let cal = work_cal(&v);
    let daily = v
        .save_event(
            Event {
                calendar_id: cal.clone(),
                title: "Daily".into(),
                start: "2026-11-02T09:30".into(),
                end: "2026-11-02T09:45".into(),
                rrule: Some("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR".into()),
                ..Default::default()
            },
            "all",
            None,
        )
        .unwrap();
    let week = v.range("2026-11-02T00:00", "2026-11-09T00:00").unwrap();
    assert_eq!(week.len(), 5);
    // Mover solo el martes a las 10:00.
    let mut moved = daily.clone();
    moved.start = "2026-11-03T10:00".into();
    moved.end = "2026-11-03T10:15".into();
    v.save_event(moved, "this", Some("2026-11-03T09:30:00")).unwrap();
    let week = v.range("2026-11-02T00:00", "2026-11-09T00:00").unwrap();
    assert_eq!(week.len(), 5);
    assert!(week.iter().any(|o| o.start == "2026-11-03T10:00:00" && !o.recurring));
    // Borrar desde el jueves en adelante.
    v.delete_event(&daily.id, "future", Some("2026-11-05T09:30:00")).unwrap();
    let week = v.range("2026-11-02T00:00", "2026-11-16T00:00").unwrap();
    assert_eq!(week.len(), 3, "{week:?}"); // lun, mar (movido), mié
}

#[test]
fn tasks_subtasks_recurrence_and_smart_lists() {
    let d = tmp("tasks");
    let v = Vault::create(&d.join("v.db"), "contraseña-larga").unwrap();
    let cal = work_cal(&v);
    let parent = v.quick_task("Preparar slides del sprint hoy a las 23:59 cada 2 semanas #sprint !!!", &cal, None).unwrap();
    assert_eq!(parent.priority, 3);
    assert_eq!(parent.tags, vec!["#sprint"]);
    assert!(parent.rrule.is_some());
    let s1 = v.quick_task("Recopilar métricas", &cal, Some(parent.id.clone())).unwrap();
    v.quick_task("Ensayar", &cal, Some(parent.id.clone())).unwrap();
    v.toggle_task(&s1.id).unwrap();
    let list = v.tasks(&TaskFilter { list_id: Some(cal.clone()), ..Default::default() }).unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!((list[0].sub_done, list[0].sub_total), (1, 2));
    let c = v.counts().unwrap();
    assert_eq!(c.today, 1);
    assert_eq!(c.tags, vec![("#sprint".to_string(), 1)]);
    // Completar una recurrente la mueve dos semanas y reabre sus subtareas.
    let before = parent.due.clone().unwrap();
    let after = v.toggle_task(&parent.id).unwrap();
    assert!(!after.completed);
    assert_ne!(after.due.clone().unwrap(), before);
    assert!(v.db.children(&parent.id).unwrap().iter().all(|c| !c.completed));
    // Una tarea normal se completa con sus subtareas.
    let t = v.quick_task("Renovar certificado TLS mañana", &cal, None).unwrap();
    // La recurrente ya pasó a dentro de dos semanas y la nueva vence mañana: «Hoy» queda vacío.
    assert_eq!(v.counts().unwrap().today, 0, "una tarea de mañana sin hora no es de hoy");
    assert!(v.tasks(&TaskFilter { smart: Some("today".into()), ..Default::default() }).unwrap().is_empty());
    assert_eq!(v.counts().unwrap().scheduled, 2);
    let sub = v.quick_task("Generar CSR", &cal, Some(t.id.clone())).unwrap();
    v.toggle_task(&t.id).unwrap();
    assert!(v.db.task(&sub.id).unwrap().completed);
    let done = v.tasks(&TaskFilter { smart: Some("completed".into()), ..Default::default() }).unwrap();
    assert_eq!(done.len(), 1);
    // Sin anidar más de un nivel.
    assert!(v.quick_task("x", &cal, Some(sub.id.clone())).is_err());
}

#[test]
fn linked_ics_file_roundtrip_and_external_edit() {
    let d = tmp("ics");
    let mut v = Vault::create(&d.join("v.db"), "contraseña-larga").unwrap();
    let ics_path = d.join("familia.ics");
    let (cal, n) = v.link_ics(&ics_path, false).unwrap();
    assert_eq!(n, 0);
    v.quick_event("Comida familiar el sábado a las 14:00", &cal.id).unwrap();
    v.quick_task("Comprar regalo para Marta #compras", &cal.id, None).unwrap();
    let txt = std::fs::read_to_string(&ics_path).unwrap();
    assert!(txt.contains("SUMMARY:Comida familiar"));
    assert!(txt.contains("CATEGORIES:compras"));
    // Otro programa edita el archivo.
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let edited = txt.replace("SUMMARY:Comida familiar", "SUMMARY:Comida en casa de la abuela");
    std::fs::write(&ics_path, edited).unwrap();
    assert_eq!(v.refresh_ics().unwrap(), 1);
    let evs = v.db.events_in_calendar(&cal.id).unwrap();
    assert_eq!(evs[0].title, "Comida en casa de la abuela");
    // Exportar e importar en un calendario nuevo.
    let out = d.join("export.ics");
    assert_eq!(v.export_ics(&cal.id, &out).unwrap(), 2);
    let (copy, n) = v.import_ics(&out, None).unwrap();
    assert_eq!(n, 2);
    assert_ne!(copy.id, cal.id);
}

#[test]
fn encrypted_backup_restore() {
    let d = tmp("bak");
    let mut v = Vault::create(&d.join("v.db"), "contraseña-larga").unwrap();
    let cal = work_cal(&v);
    v.quick_event("Demo con cliente el jueves a las 18h", &cal).unwrap();
    let t = v.quick_task("Enviar informe cada mes #cliente", &cal, None).unwrap();
    v.quick_task("Adjuntar gráficas", &cal, Some(t.id.clone())).unwrap();
    let bak = d.join("copia.calbak");
    let info = backup::create(&v.db, &bak, "clave-de-copia").unwrap();
    assert_eq!((info.events, info.tasks), (1, 2));
    let raw = std::fs::read(&bak).unwrap();
    assert!(!String::from_utf8_lossy(&raw).contains("Demo"));
    assert!(backup::inspect(&bak, "incorrecta").is_err());
    // Restaurar en una bóveda vacía.
    let mut w = Vault::create(&d.join("w.db"), "contraseña-larga").unwrap();
    backup::restore(&mut w.db, &bak, "clave-de-copia", true).unwrap();
    assert_eq!(w.db.all_events().unwrap().len(), 1);
    assert_eq!(w.db.all_tasks().unwrap().len(), 2);
    assert_eq!(w.db.children(&t.id).unwrap().len(), 1);
    drop(v);
}

fn call(method: &str, params: Value) -> Value {
    let r: Value = serde_json::from_str(&api::handle(&json!({"method": method, "params": params}).to_string())).unwrap();
    r
}

#[test]
fn json_api_end_to_end() {
    let d = tmp("api");
    let path = d.join("v.db").display().to_string();
    assert_eq!(call("vault.exists", json!({"path": path}))["data"], json!(false));
    assert_eq!(call("events.range", json!({"from": "2026-11-01", "to": "2026-11-08"}))["code"], json!("locked"));
    assert_eq!(call("vault.create", json!({"path": path, "password": "contraseña-larga"}))["ok"], json!(true));
    let cals = call("calendars.list", json!({}))["data"].clone();
    let cid = cals[0]["id"].as_str().unwrap().to_string();
    let r = call("events.save", json!({"event": {"calendarId": cid, "title": "Pádel", "start": "2026-11-03T18:00", "end": "2026-11-03T19:30", "alarms": [30]}}));
    assert_eq!(r["ok"], json!(true), "{r}");
    let occ = call("events.range", json!({"from": "2026-11-02T00:00", "to": "2026-11-09T00:00"}))["data"].clone();
    assert_eq!(occ.as_array().unwrap().len(), 1);
    assert_eq!(occ[0]["title"], json!("Pádel"));
    let al = call("alarms.between", json!({"from": "2026-11-03T17:00", "to": "2026-11-03T18:00"}))["data"].clone();
    assert_eq!(al[0]["at"], json!("2026-11-03T17:30:00"));
    let t = call("tasks.quickAdd", json!({"text": "Reservar pista mañana a las 17h", "listId": cid}));
    assert_eq!(t["ok"], json!(true));
    let found = call("search", json!({"q": "pista"}))["data"]["tasks"].clone();
    assert_eq!(found.as_array().unwrap().len(), 1);
    assert_eq!(call("nope", json!({}))["ok"], json!(false));
    assert_eq!(call("events.save", json!({"event": {"calendarId": cid, "title": "", "start": "x", "end": "y"}}))["code"], json!("invalid"));
    // Mover la bóveda a otra carpeta (portable) sin volver a pedir la contraseña.
    let moved = d.join("portable").join("datos.calendario").display().to_string();
    assert_eq!(call("vault.relocate", json!({"path": moved}))["ok"], json!(true));
    assert!(!std::path::Path::new(&path).exists());
    assert_eq!(call("search", json!({"q": "pista"}))["data"]["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(call("vault.relocate", json!({"path": moved}))["ok"], json!(true), "misma ruta: no hace nada");
    let path = moved;
    assert_eq!(call("vault.lock", json!({}))["ok"], json!(true));
    assert_eq!(call("vault.open", json!({"path": path, "password": "mal"}))["code"], json!("wrong_password"));
}

#[test]
fn attachments_documents_links_folders() {
    let d = tmp("att");
    let v = Vault::create(&d.join("v.db"), "contraseña-larga").unwrap();
    let cal = work_cal(&v);
    let t = v.quick_task("Preparar contrato", &cal, None).unwrap();
    let doc = d.join("contrato.pdf");
    std::fs::write(&doc, b"%PDF-1.7 contenido secreto").unwrap();
    let a = v.add_attachment("task", &t.id, "file", &doc.display().to_string(), None).unwrap();
    assert_eq!((a.name.as_str(), a.size), ("contrato.pdf", 26));
    let l = v.add_attachment("task", &t.id, "link", "ejemplo.es/doc", Some("Borrador")).unwrap();
    assert_eq!(l.target, "https://ejemplo.es/doc");
    assert_eq!(l.name, "Borrador");
    let f = v.add_attachment("task", &t.id, "folder", &d.display().to_string(), None).unwrap();
    assert!(v.add_attachment("task", &t.id, "link", "no es un enlace", None).is_err());
    assert!(v.add_attachment("task", &t.id, "folder", "/no/existe", None).is_err());
    assert_eq!(v.db.attachments(&t.id).unwrap().len(), 3);
    // El documento está copiado: aunque se borre el original, se puede abrir.
    std::fs::remove_file(&doc).unwrap();
    let opened = v.open_attachment(&a.id).unwrap();
    assert_eq!(std::fs::read(&opened).unwrap(), b"%PDF-1.7 contenido secreto");
    assert_eq!(v.open_attachment(&f.id).unwrap(), d.display().to_string());
    // Va cifrado: el contenido no aparece en claro en la base de datos.
    drop(v);
    let raw = std::fs::read(d.join("v.db")).unwrap();
    assert!(!raw.windows(17).any(|w| w == b"contenido secreto"));
    let v = Vault::open(&d.join("v.db"), "contraseña-larga").unwrap();
    // Viaja en las copias de seguridad.
    let bak = d.join("c.calbak");
    backup::create(&v.db, &bak, "clave-de-copia").unwrap();
    let mut w = Vault::create(&d.join("w.db"), "contraseña-larga").unwrap();
    backup::restore(&mut w.db, &bak, "clave-de-copia", true).unwrap();
    assert_eq!(w.db.attachments(&t.id).unwrap().len(), 3);
    assert!(w.open_attachment(&a.id).is_ok());
    // Al borrar la tarea se borran sus adjuntos.
    v.delete_task(&t.id).unwrap();
    assert!(v.db.attachments(&t.id).unwrap().is_empty());
    let list = v.tasks(&TaskFilter { list_id: Some(cal), ..Default::default() }).unwrap();
    assert!(list.is_empty());
}
