//! Interfaz C mínima para Dart (dart:ffi). Sin generadores de código: JSON de entrada y de salida.
//!
//! Uso desde Dart: reservar `len + 1` bytes con `cal_alloc`, copiar la petición UTF-8 terminada en 0,
//! llamar a `cal_call`, leer la respuesta y liberarla con `cal_free`; liberar la petición con `cal_dealloc`.
use std::ffi::{c_char, CStr, CString};

#[no_mangle]
pub extern "C" fn cal_alloc(len: usize) -> *mut u8 {
    let mut v = vec![0u8; len.max(1)];
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

/// # Safety
/// `ptr` y `len` deben venir de `cal_alloc`.
#[no_mangle]
pub unsafe extern "C" fn cal_dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Vec::from_raw_parts(ptr, len.max(1), len.max(1)));
    }
}

/// # Safety
/// `request` debe ser una cadena UTF-8 terminada en 0.
#[no_mangle]
pub unsafe extern "C" fn cal_call(request: *const c_char) -> *mut c_char {
    let req = if request.is_null() { String::new() } else { CStr::from_ptr(request).to_string_lossy().into_owned() };
    let resp = std::panic::catch_unwind(|| crate::api::handle(&req)).unwrap_or_else(|_| {
        r#"{"ok":false,"error":"error interno del núcleo","code":"panic"}"#.to_string()
    });
    CString::new(resp.replace('\0', "")).unwrap().into_raw()
}

/// # Safety
/// `s` debe venir de `cal_call`.
#[no_mangle]
pub unsafe extern "C" fn cal_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
