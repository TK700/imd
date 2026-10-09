#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rfd::FileDialog;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{DragDropEvent, Emitter, Manager, WindowEvent};

#[derive(Serialize, Clone)]
struct OpenedDoc { path: String, name: String, text: String }

struct Pending(Mutex<HashMap<String, serde_json::Value>>);

#[tauri::command]
fn put_pending(state: tauri::State<Pending>, key: String, doc: serde_json::Value) {
    state.0.lock().unwrap().insert(key, doc);
}
#[tauri::command]
fn take_pending(state: tauri::State<Pending>, key: String) -> Option<serde_json::Value> {
    state.0.lock().unwrap().remove(&key)
}
#[tauri::command]
fn del_pending(state: tauri::State<Pending>, key: String) {
    state.0.lock().unwrap().remove(&key);
}
#[tauri::command]
fn set_flag(state: tauri::State<Pending>, key: String) {
    state.0.lock().unwrap().insert(key, serde_json::Value::Bool(true));
}
#[tauri::command]
fn take_flag(state: tauri::State<Pending>, key: String) -> bool {
    matches!(state.0.lock().unwrap().remove(&key), Some(serde_json::Value::Bool(true)))
}

fn name_of(p: &PathBuf) -> String {
    p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Untitled.md".into())
}

#[tauri::command]
fn open_file() -> Option<OpenedDoc> {
    let p = FileDialog::new().add_filter("Markdown", &["md", "markdown", "mdown", "mkd", "txt"]).pick_file()?;
    let text = fs::read_to_string(&p).ok()?;
    Some(OpenedDoc { path: p.to_string_lossy().to_string(), name: name_of(&p), text })
}

#[tauri::command]
fn open_path(path: String) -> Option<OpenedDoc> {
    let p = PathBuf::from(&path);
    if !p.is_file() { return None; }
    let text = fs::read_to_string(&p).ok()?;
    Some(OpenedDoc { path: p.to_string_lossy().to_string(), name: name_of(&p), text })
}

#[tauri::command]
fn startup_paths(state: tauri::State<Vec<String>>) -> Vec<String> {
    state.inner().clone()
}

#[tauri::command]
fn window_at(app: tauri::AppHandle, x: f64, y: f64, exclude: String) -> Option<String> {
    for (label, w) in app.webview_windows() {
        if label == exclude { continue; }
        let (Ok(pos), Ok(size)) = (w.outer_position(), w.outer_size()) else { continue };
        let (wx, wy) = (pos.x as f64, pos.y as f64);
        let (ww, wh) = (size.width as f64, size.height as f64);
        if x >= wx && x <= wx + ww && y >= wy && y <= wy + wh { return Some(label); }
    }
    None
}

#[tauri::command]
fn save_file(path: String, content: String) -> bool {
    if path.is_empty() { return false; }
    fs::write(&path, content).is_ok()
}

#[tauri::command]
fn save_as(default_name: String, content: String) -> Option<OpenedDoc> {
    let p = FileDialog::new().set_file_name(&default_name).add_filter("Markdown", &["md", "markdown", "txt"]).save_file()?;
    match fs::write(&p, &content) {
        Ok(_) => Some(OpenedDoc { path: p.to_string_lossy().to_string(), name: name_of(&p), text: content }),
        Err(_) => None,
    }
}

fn main() {
    let startup_args: Vec<String> = std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with('-') && std::path::Path::new(a).exists())
        .collect();

    tauri::Builder::default()
        .manage(startup_args)
        .manage(Pending(Mutex::new(HashMap::new())))
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            let paths: Vec<String> = args.iter().skip(1)
                .filter(|a| std::path::Path::new(a).is_file())
                .cloned().collect();
            if !paths.is_empty() {
                let _ = app.emit_to("main", "imd:open-paths", paths);
            }
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_focus();
            } else if let Some(w) = app.webview_windows().values().next() {
                let _ = w.set_focus();
            }
        }))
        .on_window_event(|window, event| {
            if let WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = event {
                let ps: Vec<String> = paths.iter().map(|p| p.to_string_lossy().to_string()).collect();
                let _ = window.emit("imd:open-paths", ps);
            }
        })
        .invoke_handler(tauri::generate_handler![
            open_file, open_path, startup_paths, save_file, save_as,
            put_pending, take_pending, del_pending, set_flag, take_flag, window_at
        ])
        .run(tauri::generate_context!())
        .expect("error while running imd");
}
