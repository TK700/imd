#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rfd::FileDialog;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;
use tauri::{DragDropEvent, Emitter, Manager, WindowEvent};

#[derive(Serialize, Clone)]
struct OpenedDoc { path: String, name: String, text: String }

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
        .on_window_event(|window, event| {
            if let WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = event {
                let ps: Vec<String> = paths.iter().map(|p| p.to_string_lossy().to_string()).collect();
                let _ = window.emit("imd:open-paths", ps);
            }
        })
        .invoke_handler(tauri::generate_handler![open_file, open_path, startup_paths, save_file, save_as])
        .run(tauri::generate_context!())
        .expect("error while running imd");
}
