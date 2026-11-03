//! Anclaje de los widgets al escritorio para que sigan visibles con Win+D o «Mostrar escritorio».
#[allow(unused_imports)]
use crate::error::{Error, Result};

#[cfg(all(windows, target_pointer_width = "64"))]
pub fn pin_to_desktop(title: &str) -> Result<bool> {
    use std::ptr::null;
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }
    unsafe extern "system" fn find_defview(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let cls = wide("SHELLDLL_DefView");
        let dv = FindWindowExW(hwnd, std::ptr::null_mut(), cls.as_ptr(), null());
        if !dv.is_null() {
            *(lparam as *mut HWND) = dv;
            return 0;
        }
        1
    }
    unsafe {
        let hwnd = FindWindowW(null(), wide(title).as_ptr());
        if hwnd.is_null() {
            return Err(Error::NotFound(format!("ventana «{title}»")));
        }
        let progman = FindWindowW(wide("Progman").as_ptr(), null());
        let mut defview = FindWindowExW(progman, std::ptr::null_mut(), wide("SHELLDLL_DefView").as_ptr(), null());
        if defview.is_null() {
            EnumWindows(Some(find_defview), &mut defview as *mut HWND as LPARAM);
        }
        let owner = if defview.is_null() { progman } else { defview };
        // Propietario = escritorio: «Mostrar escritorio» ya no oculta la ventana.
        SetWindowLongPtrW(hwnd, GWLP_HWNDPARENT, owner as isize);
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW as isize) & !(WS_EX_APPWINDOW as isize));
        // Una sola vez al fondo; no se fuerza en cada movimiento (eso provocaba parpadeos y bloqueaba el arrastre).
        SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        Ok(true)
    }
}

#[cfg(target_os = "macos")]
pub fn pin_to_desktop(title: &str) -> Result<bool> {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use std::ffi::{c_void, CStr};

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowLevelForKey(key: i32) -> i32;
    }
    extern "C" {
        static _dispatch_main_q: c_void;
        fn dispatch_async_f(queue: *const c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
    }
    extern "C" fn work(ctx: *mut c_void) {
        let title = unsafe { Box::from_raw(ctx as *mut String) };
        unsafe {
            let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
            let windows: *mut AnyObject = msg_send![app, windows];
            let count: usize = msg_send![windows, count];
            for i in 0..count {
                let w: *mut AnyObject = msg_send![windows, objectAtIndex: i];
                let t: *mut AnyObject = msg_send![w, title];
                if t.is_null() {
                    continue;
                }
                let s: *const std::ffi::c_char = msg_send![t, UTF8String];
                if !s.is_null() && CStr::from_ptr(s).to_string_lossy() == title.as_str() {
                    // Justo encima de los iconos del escritorio; visible en todos los Spaces y fijo con Exposé.
                    let level = CGWindowLevelForKey(18) as isize + 1; // kCGDesktopIconWindowLevelKey
                    let _: () = msg_send![w, setLevel: level];
                    let behavior: usize = (1 << 0) | (1 << 4) | (1 << 6); // CanJoinAllSpaces | Stationary | IgnoresCycle
                    let _: () = msg_send![w, setCollectionBehavior: behavior];
                }
            }
        }
    }
    let ctx = Box::into_raw(Box::new(title.to_string())) as *mut c_void;
    unsafe { dispatch_async_f(&_dispatch_main_q as *const c_void, ctx, work) };
    Ok(true)
}

/// En Linux el anclaje lo hace la propia app (window_manager: siempre al fondo, en todos los escritorios).
#[cfg(not(any(all(windows, target_pointer_width = "64"), target_os = "macos")))]
pub fn pin_to_desktop(_title: &str) -> Result<bool> {
    Ok(false)
}

/// Diálogo nativo de archivos. `mode`: "open", "save" o "folder". Devuelve la ruta elegida o None si se cancela.
pub fn pick_file(mode: &str, title: &str, filter_name: &str, extensions: &[String], default_name: Option<&str>) -> Option<String> {
    let mut d = rfd::FileDialog::new().set_title(title);
    if !extensions.is_empty() {
        let ext: Vec<&str> = extensions.iter().map(|s| s.as_str()).collect();
        d = d.add_filter(filter_name, &ext);
    }
    if let Some(n) = default_name {
        d = d.set_file_name(n);
    }
    let r = match mode {
        "save" => d.save_file(),
        "folder" => d.pick_folder(),
        _ => d.pick_file(),
    };
    r.map(|p| p.display().to_string())
}

/// Notificación del sistema (avisos de eventos y tareas).
pub fn notify(title: &str, body: &str) -> Result<bool> {
    notify_rust::Notification::new()
        .appname("Calendario y Tareas")
        .summary(title)
        .body(body)
        .show()
        .map(|_| true)
        .map_err(|e| Error::Invalid(format!("no se pudo mostrar la notificación: {e}")))
}
