//! The Listen Router as a desktop app: the same router as `listen-router`, with a window and a tray icon.
//! Closing the window keeps the router running; it is quit from the tray icon's menu.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use listen_router::running::{default_home, Options, Running};
use listen_router::settings::{Settings, TopicView};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as _};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, State, WindowEvent};

/// The router, or why it did not start.
struct Router(Mutex<Result<Running, String>>);

fn view(router: &Result<Running, String>) -> Value {
    match router {
        Ok(running) => serde_json::to_value(running.snapshot()).unwrap_or(Value::Null),
        Err(problem) => json!({
            "version": env!("CARGO_PKG_VERSION"),
            "ready": false,
            "startFailed": true,
            "problem": problem,
            "folder": std::env::var_os("LISTEN_ROUTER_HOME").map(std::path::PathBuf::from).unwrap_or_else(default_home).display().to_string(),
            "tools": [], "devices": [], "sessions": [], "activity": [],
            "answering": false
        }),
    }
}

/// Whether somebody can see the window. Hidden (closed to the tray) or minimised, it shows nothing.
fn on_screen(window: &tauri::WebviewWindow) -> bool {
    window.is_visible().unwrap_or(false) && !window.is_minimized().unwrap_or(false)
}

/// Asked by the window once a second. Only a window on screen keeps the pairing code alive and renewed.
#[tauri::command]
fn state(window: tauri::WebviewWindow, router: State<Router>) -> Value {
    let router = router.0.lock().unwrap();
    if let (Ok(running), true) = (router.as_ref(), on_screen(&window)) {
        running.pairing_seen();
    }
    view(&router)
}

/// The owner asks for a pairing code after the renewal stopped.
#[tauri::command]
fn show_code(router: State<Router>) -> Value {
    let router = router.0.lock().unwrap();
    if let Ok(running) = router.as_ref() {
        running.show_pairing();
    }
    view(&router)
}

/// The owner copied the shown link: its code stays a full period longer, time enough to paste it.
#[tauri::command]
fn keep_code(router: State<Router>) -> Value {
    let router = router.0.lock().unwrap();
    if let Ok(running) = router.as_ref() {
        running.hold_pairing();
    }
    view(&router)
}

#[tauri::command]
fn remove_device(router: State<Router>, id: String) -> Value {
    let router = router.0.lock().unwrap();
    if let Ok(running) = router.as_ref() {
        running.remove_device(&id);
    }
    view(&router)
}

#[tauri::command]
fn settings(router: State<Router>) -> Result<Settings, String> {
    router.0.lock().unwrap().as_ref().map(|r| r.settings()).map_err(|e| e.clone())
}

/// Stores new settings. A widening comes back as `needsConfirmation` with its warnings until `confirmed`.
#[tauri::command]
fn save_settings(app: AppHandle, router: State<Router>, settings: Settings, confirmed: bool) -> Result<Value, Value> {
    let autostart = settings.autostart;
    let saved = {
        let router = router.0.lock().unwrap();
        let running = router.as_ref().map_err(|e| json!({"kind": "invalid", "detail": e}))?;
        running.save_settings(settings, confirmed).map_err(|e| serde_json::to_value(e).unwrap_or(Value::Null))?
    };
    let launcher = app.autolaunch();
    let result = if autostart { launcher.enable() } else { launcher.disable() };
    let autostart_error = result.err().map(|e| e.to_string());
    Ok(json!({"restartNeeded": saved.restart_needed, "autostartError": autostart_error}))
}

#[tauri::command]
fn topics(router: State<Router>) -> Vec<TopicView> {
    router.0.lock().unwrap().as_ref().map(|r| r.topics()).unwrap_or_default()
}

/// Lets the owner pick a folder; the path goes back into the settings form.
#[tauri::command]
async fn choose_folder(app: AppHandle) -> Option<String> {
    app.dialog().file().blocking_pick_folder().and_then(|p| p.into_path().ok()).map(|p| p.display().to_string())
}

/// Opens a folder the router knows in the system's file manager: its own, or a topic's. Nothing else.
#[tauri::command]
fn open_folder(app: AppHandle, router: State<Router>, which: String) -> Result<(), String> {
    let path = {
        let router = router.0.lock().unwrap();
        let running = router.as_ref().map_err(|e| e.clone())?;
        if which == "router" {
            running.home.root().display().to_string()
        } else {
            let id = which.strip_prefix("topic:").ok_or("unknown folder")?;
            running.topics().into_iter().find(|t| t.id == id).map(|t| t.folder).ok_or("no such topic")?
        }
    };
    app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
}

fn show(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// Ends every session cleanly, then the app.
fn quit(app: &AppHandle) {
    let router = app.state::<Router>();
    let taken = std::mem::replace(&mut *router.0.lock().unwrap(), Err("stopped".into()));
    if let Ok(running) = taken {
        tauri::async_runtime::block_on(running.stop());
    }
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        // Started with the system it comes up hidden, in the tray only.
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .setup(|app| {
            if std::env::args().any(|a| a == "--hidden") {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            // `LISTEN_ROUTER_HOME` points the app at another folder, for trying it without touching ~/Listen.
            let home = std::env::var_os("LISTEN_ROUTER_HOME").map(std::path::PathBuf::from);
            let started = tauri::async_runtime::block_on(Running::start(Options { home, bonjour: true, ..Options::default() }))
                .map_err(|e| e.to_string());
            app.manage(Router(Mutex::new(started)));

            let open = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
            let link = MenuItem::with_id(app, "link", "Pair a device", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit Listen Router", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &link, &quit_item])?;
            let mut tray = TrayIconBuilder::with_id("router")
                .tooltip("Listen Router")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show(app),
                    "link" => {
                        if let Ok(running) = app.state::<Router>().0.lock().unwrap().as_ref() {
                            running.show_pairing();
                        }
                        show(app);
                    }
                    "quit" => quit(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show(tray.app_handle());
                    }
                });
            // macOS uses a monochrome template, adapted by the menu bar to its theme.
            // Other platforms retain the full-colour app mark.
            #[cfg(target_os = "macos")]
            let tray_bytes: &[u8] = include_bytes!("../icons/tray.png");
            #[cfg(not(target_os = "macos"))]
            let tray_bytes: &[u8] = include_bytes!("../icons/32x32.png");
            match tauri::image::Image::from_bytes(tray_bytes) {
                Ok(icon) => tray = tray.icon(icon),
                Err(_) => {
                    if let Some(icon) = app.default_window_icon() {
                        tray = tray.icon(icon.clone());
                    }
                }
            }
            #[cfg(target_os = "macos")]
            { tray = tray.icon_as_template(true); }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window only hides it; the router keeps serving.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            state,
            show_code,
            keep_code,
            remove_device,
            settings,
            save_settings,
            topics,
            choose_folder,
            open_folder
        ])
        .run(tauri::generate_context!())
        .expect("the Listen Router app could not start");
}
