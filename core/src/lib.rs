//! Núcleo de Calendario y Tareas.
//!
//! Local primero: toda la información vive en una base de datos SQLCipher del equipo. Los conectores
//! (.ics y CalDAV) sincronizan cuando hay red; la futura sincronización con el servidor zero-knowledge
//! partirá del registro de cambios (`changes`) y del sobre cifrado de `backup`.
pub mod api;
pub mod backup;
pub mod caldav;
pub mod db;
pub mod desktop;
pub mod endpoints;
pub mod error;
pub mod ffi;
pub mod ics;
pub mod model;
pub mod nlp;
pub mod recur;
pub mod time;
pub mod vault;
pub mod zk;
