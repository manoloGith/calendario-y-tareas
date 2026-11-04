//! calendario-zk-server — servidor de sincronización zero-knowledge.
//!
//! Configuración por variables de entorno (o argumentos `--clave=valor` equivalentes):
//!   CALZK_LISTEN     dirección de escucha (por defecto 0.0.0.0:8787)
//!   CALZK_DB         archivo de la base de datos (por defecto ./calendario-zk.db)
//!   CALZK_REGISTER   «true» (por defecto) o «false» para impedir crear cuentas nuevas
//!   CALZK_TLS_CERT   certificado PEM para HTTPS (opcional)
//!   CALZK_TLS_KEY    clave privada PEM para HTTPS (opcional)
use std::net::SocketAddr;
use std::path::PathBuf;

fn setting(args: &[String], name: &str, env: &str, default: &str) -> String {
    let flag = format!("--{name}=");
    args.iter()
        .find_map(|a| a.strip_prefix(&flag).map(|s| s.to_string()))
        .or_else(|| std::env::var(env).ok())
        .unwrap_or_else(|| default.to_string())
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!(
            "calendario-zk-server {}\n\nOpciones (o variables de entorno):\n  --listen=0.0.0.0:8787   CALZK_LISTEN\n  --db=calendario-zk.db   CALZK_DB\n  --register=true|false   CALZK_REGISTER\n  --tls-cert=cert.pem     CALZK_TLS_CERT\n  --tls-key=key.pem       CALZK_TLS_KEY",
            calendario_zk_server::VERSION
        );
        return;
    }
    let listen = setting(&args, "listen", "CALZK_LISTEN", "0.0.0.0:8787");
    let db = PathBuf::from(setting(&args, "db", "CALZK_DB", "calendario-zk.db"));
    let register = setting(&args, "register", "CALZK_REGISTER", "true") != "false";
    let cert = setting(&args, "tls-cert", "CALZK_TLS_CERT", "");
    let key = setting(&args, "tls-key", "CALZK_TLS_KEY", "");

    let state = calendario_zk_server::open(&db, register).unwrap_or_else(|e| {
        eprintln!("No se puede abrir la base de datos {}: {e}", db.display());
        std::process::exit(1);
    });
    let app = calendario_zk_server::router(state);
    let addr: SocketAddr = listen.parse().unwrap_or_else(|_| {
        eprintln!("Dirección de escucha no válida: {listen}");
        std::process::exit(1);
    });
    println!(
        "Calendario y Tareas · servidor zero-knowledge {} escuchando en {}://{} (datos: {}, registro {})",
        calendario_zk_server::VERSION,
        if cert.is_empty() { "http" } else { "https" },
        addr,
        db.display(),
        if register { "abierto" } else { "cerrado" }
    );
    if cert.is_empty() {
        let listener = tokio::net::TcpListener::bind(addr).await.unwrap_or_else(|e| {
            eprintln!("No se puede escuchar en {addr}: {e}");
            std::process::exit(1);
        });
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = tokio::signal::ctrl_c().await;
            })
            .await
            .unwrap();
    } else {
        let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert, &key).await.unwrap_or_else(|e| {
            eprintln!("No se puede cargar el certificado TLS: {e}");
            std::process::exit(1);
        });
        axum_server::bind_rustls(addr, tls).serve(app.into_make_service()).await.unwrap();
    }
}
