//! Prueba de extremo a extremo: servidor ZK real + varios «equipos» con el núcleo de la app.
use calendario_core::model::*;
use calendario_core::vault::{TaskFilter, Vault};
use calendario_core::{api, zk};
use std::path::PathBuf;

const PW: &str = "contraseña-de-la-boveda";
const SYNC_PW: &str = "sincronizar-segura-2026";

fn tmp(name: &str) -> PathBuf {
    std::env::set_var("CALENDARIO_TZ", "Europe/Madrid");
    let d = std::env::temp_dir().join(format!("zk-{}-{}", name, uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Arranca el servidor en un puerto libre y devuelve (URL, ruta de su base de datos).
fn start_server() -> (String, PathBuf) {
    let dir = tmp("server");
    let db = dir.join("zk.db");
    let state = calendario_zk_server::open(&db, true).unwrap();
    let app = calendario_zk_server::router(state);
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            tx.send(l.local_addr().unwrap()).unwrap();
            axum::serve(l, app).await.unwrap();
        });
    });
    let addr = rx.recv().unwrap();
    (format!("http://{addr}/"), db)
}

fn sync(path: &PathBuf) -> zk::ZkStats {
    let r = zk::sync_all(path, PW, None).unwrap();
    r[0].1.clone().unwrap_or_else(|e| panic!("sync: {e}"))
}

fn personal(v: &Vault) -> String {
    v.db.calendars().unwrap().into_iter().find(|c| c.name == "Personal").unwrap().id
}

#[test]
fn two_devices_end_to_end() {
    let (url, server_db) = start_server();
    let dead = "http://127.0.0.1:9/".to_string(); // dirección «local» que no responde

    // ---------------- Equipo A: datos, alta en el servidor y primera subida
    let da = tmp("a");
    let pa = da.join("v.db");
    let a = Vault::create(&pa, PW).unwrap();
    let cal = personal(&a);
    let ev = a.quick_event("Cena secreta con Ana el viernes a las 21h", &cal).unwrap();
    let task = a.quick_task("Comprar regalo sorpresa mañana #cumple", &cal, None).unwrap();
    let sub = a.quick_task("Envolverlo", &cal, Some(task.id.clone())).unwrap();
    let doc = da.join("nota.txt");
    std::fs::write(&doc, "contenido del adjunto").unwrap();
    a.add_attachment("task", &task.id, "file", &doc.display().to_string(), None).unwrap();
    let linked = zk::register(&a.db, "Mi servidor", &[dead.clone(), url.clone()], "ana", SYNC_PW).unwrap();
    let code = linked.recovery_code.clone().unwrap();
    assert_eq!(code.len(), 29);
    assert_eq!(linked.account.active_url.as_deref(), Some(url.as_str()), "debe usar la dirección que responde");
    let s = sync(&pa);
    assert!(s.uploaded >= 6, "{s:?}"); // 2 calendarios, evento, tarea, subtarea, adjunto

    // El servidor no ve nada en claro.
    let raw = std::fs::read(&server_db).unwrap();
    for secret in ["Cena secreta", "regalo sorpresa", "contenido del adjunto", "Personal", "cumple"] {
        assert!(!raw.windows(secret.len()).any(|w| w == secret.as_bytes()), "«{secret}» aparece en claro en el servidor");
    }

    // ---------------- Equipo B: se une a la cuenta y recibe todo, sin duplicar «Personal»/«Trabajo»
    let pb = tmp("b").join("v.db");
    let b = Vault::create(&pb, PW).unwrap();
    assert!(zk::login(&b.db, "", &[url.clone()], "ana", "contraseña-mala-123").is_err());
    zk::login(&b.db, "", &[url.clone()], "ana", SYNC_PW).unwrap();
    sync(&pb);
    let names: Vec<String> = b.db.calendars().unwrap().into_iter().map(|c| c.name).collect();
    assert_eq!(names.iter().filter(|n| *n == "Personal").count(), 1, "{names:?}");
    assert_eq!(b.db.event(&ev.id).unwrap().title, "Cena secreta con Ana");
    let bt = b.tasks(&TaskFilter { list_id: Some(cal.clone()), ..Default::default() }).unwrap();
    assert_eq!(bt.len(), 1);
    assert_eq!((bt[0].sub_total, bt[0].attachments), (1, 1));
    let att = b.db.attachments(&task.id).unwrap();
    assert_eq!(std::fs::read_to_string(b.open_attachment(&att[0].id).unwrap()).unwrap(), "contenido del adjunto");

    // ---------------- Trabajo «sin conexión» en los dos y convergencia
    let mut e = b.db.event(&ev.id).unwrap();
    e.location = "Casa Lucio".into();
    b.save_event(e, "all", None).unwrap();
    a.delete_task(&sub.id).unwrap();
    let nuevo = a.quick_event("Dentista el 12 de noviembre a las 11h", &cal).unwrap();
    sync(&pb);
    sync(&pa);
    sync(&pb);
    assert_eq!(a.db.event(&ev.id).unwrap().location, "Casa Lucio");
    assert!(b.db.task(&sub.id).is_err(), "la subtarea borrada en A debe borrarse en B");
    assert_eq!(b.db.event(&nuevo.id).unwrap().title, "Dentista");
    // Sin cambios: nada que subir ni bajar.
    let s = sync(&pa);
    assert_eq!((s.uploaded, s.downloaded), (0, 0), "{s:?}");

    // ---------------- Conflicto: los dos editan el mismo evento; gana el más reciente
    let mut ea = a.db.event(&ev.id).unwrap();
    ea.notes = "versión de A".into();
    a.save_event(ea, "all", None).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let mut eb = b.db.event(&ev.id).unwrap();
    eb.notes = "versión de B".into();
    b.save_event(eb, "all", None).unwrap();
    sync(&pa);
    let s = sync(&pb);
    assert_eq!(s.conflicts, 1, "{s:?}");
    sync(&pa);
    assert_eq!(a.db.event(&ev.id).unwrap().notes, "versión de B");
    assert_eq!(b.db.event(&ev.id).unwrap().notes, "versión de B");

    // ---------------- Calendario nuevo y borrado de calendario
    let mut c2 = Calendar { id: String::new(), name: "Viajes".into(), color: "#34C759".into(), kind: "both".into(), source: SOURCE_LOCAL.into(), visible: true, position: 5, ics_path: None, account_id: None, remote_url: None, ctag: None, readonly: false };
    a.db.save_calendar(&mut c2).unwrap();
    a.quick_event("Vuelo a Lisboa el 20 de noviembre a las 8:05", &c2.id).unwrap();
    sync(&pa);
    sync(&pb);
    assert_eq!(b.db.events_in_calendar(&c2.id).unwrap().len(), 1);
    b.db.delete_calendar(&c2.id).unwrap();
    sync(&pb);
    sync(&pa);
    assert!(a.db.calendar(&c2.id).is_err());

    // ---------------- Cambio de contraseña: cierra las otras sesiones
    let acc_a = zk::accounts(&a.db).unwrap().remove(0);
    zk::change_password(&a.db, &acc_a.id, "nueva-clave-de-sync").unwrap();
    let r = zk::sync_all(&pb, PW, None).unwrap();
    assert!(r[0].1.as_ref().unwrap_err().contains("caducado"), "{r:?}");
    let acc_b = zk::accounts(&b.db).unwrap().remove(0);
    zk::remove_account(&b.db, &acc_b.id).unwrap();
    assert!(zk::login(&b.db, "", &[url.clone()], "ana", SYNC_PW).is_err());
    zk::login(&b.db, "", &[url.clone()], "ana", "nueva-clave-de-sync").unwrap();
    sync(&pb);

    // ---------------- Equipo C: recuperación con el código (contraseña olvidada)
    let pc = tmp("c").join("v.db");
    let c = Vault::create(&pc, PW).unwrap();
    assert!(zk::recover(&c.db, "", &[url.clone()], "ana", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", "otra-clave-larga").is_err());
    zk::recover(&c.db, "", &[url.clone()], "ana", &code.to_lowercase().replace('-', " "), "otra-clave-larga").unwrap();
    sync(&pc);
    assert_eq!(c.db.event(&ev.id).unwrap().notes, "versión de B");
    assert!(zk::login(&c.db, "", &[url.clone()], "ana", "otra-clave-larga").is_ok());

    // ---------------- API JSON: prueba de conexión
    let j: serde_json::Value = serde_json::from_str(&api::handle(
        &serde_json::json!({"method": "zk.test", "params": {"urls": [dead, url]}}).to_string(),
    ))
    .unwrap();
    assert_eq!(j["data"][0]["ok"], serde_json::json!(false));
    assert_eq!(j["data"][1]["ok"], serde_json::json!(true));
}
