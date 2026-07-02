use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager, Monitor, State, WebviewWindow,
};

mod platform;

/// 현재 배치된 디스플레이 인덱스 (available_monitors 를 x좌표로 정렬한 순서)
struct AppState {
    display_index: Mutex<usize>,
    /// 캐릭터가 잡혀(드래그) 있는 동안 true — 커서 폴링 스레드가 크로스모니터 이동에 사용
    grabbed: AtomicBool,
}

/// 모니터들을 화면 왼쪽→오른쪽(x) 순으로 정렬 (main.swift 의 screensSorted 와 동일 개념)
fn sorted_monitors(win: &WebviewWindow) -> Vec<Monitor> {
    let mut ms = win.available_monitors().unwrap_or_default();
    ms.sort_by(|a, b| a.position().x.cmp(&b.position().x));
    ms
}

// ── 전역 비교좌표계 ──
// 커서·모니터·창 위치를 서로 비교하려면 같은 공간이어야 하는데 tao 의 "물리좌표"는
// macOS 에서 커서=Cocoa포인트×주모니터scale, 모니터/창=포인트×각자scale 로 제각각이다.
// → macOS 는 논리(포인트) 공간으로 되돌려 비교, Windows 는 가상 스크린 물리픽셀 그대로.

/// 전역 커서 위치 (비교좌표계)
#[cfg(target_os = "macos")]
fn cursor_global(win: &WebviewWindow) -> Option<(f64, f64)> {
    let c = win.cursor_position().ok()?;
    let ps = win.primary_monitor().ok().flatten()?.scale_factor();
    Some((c.x / ps, c.y / ps))
}
#[cfg(not(target_os = "macos"))]
fn cursor_global(win: &WebviewWindow) -> Option<(f64, f64)> {
    let c = win.cursor_position().ok()?;
    Some((c.x, c.y))
}

/// 모니터 rect (비교좌표계) → (x, y, w, h)
#[cfg(target_os = "macos")]
fn monitor_rect_global(m: &Monitor) -> (f64, f64, f64, f64) {
    let s = m.scale_factor();
    let p = m.position().to_logical::<f64>(s);
    let sz = m.size().to_logical::<f64>(s);
    (p.x, p.y, sz.width, sz.height)
}
#[cfg(not(target_os = "macos"))]
fn monitor_rect_global(m: &Monitor) -> (f64, f64, f64, f64) {
    let p = m.position();
    let sz = m.size();
    (p.x as f64, p.y as f64, sz.width as f64, sz.height as f64)
}

/// 커서의 창-로컬 CSS px 좌표 (webview 의 clientX/Y 와 같은 공간)
#[cfg(target_os = "macos")]
fn cursor_local(win: &WebviewWindow) -> Option<(f64, f64)> {
    let (cx, cy) = cursor_global(win)?;
    let wp = win.outer_position().ok()?;
    let ws = win.scale_factor().ok()?;
    Some((cx - wp.x as f64 / ws, cy - wp.y as f64 / ws))
}
#[cfg(not(target_os = "macos"))]
fn cursor_local(win: &WebviewWindow) -> Option<(f64, f64)> {
    let c = win.cursor_position().ok()?;
    let wp = win.outer_position().ok()?;
    let ws = win.scale_factor().ok()?;
    Some(((c.x - wp.x as f64) / ws, (c.y - wp.y as f64) / ws))
}

/// 전역 커서가 있는 모니터 인덱스 (sorted_monitors 순서)
fn monitor_under_cursor(win: &WebviewWindow, ms: &[Monitor]) -> Option<usize> {
    let (cx, cy) = cursor_global(win)?;
    ms.iter().position(|m| {
        let (x, y, w, h) = monitor_rect_global(m);
        cx >= x && cx < x + w && cy >= y && cy < y + h
    })
}

/// 창을 해당 모니터 전체로 맞춤. 혼합 DPI 대응: 물리픽셀을 그 모니터의 scale 로
/// logical 로 변환해 set_position/set_size (Phase 1 에서 물리픽셀 직접 지정 시 어긋났음).
#[cfg(target_os = "macos")]
fn fit_to_monitor(win: &WebviewWindow, m: &Monitor) {
    use tauri::{LogicalPosition, LogicalSize};
    let scale = m.scale_factor();
    let p = m.position().to_logical::<f64>(scale);
    let s = m.size().to_logical::<f64>(scale);
    let _ = win.set_position(LogicalPosition::new(p.x, p.y));
    let _ = win.set_size(LogicalSize::new(s.width, s.height));
    // macOS: 메뉴바 때문에 창 top 이 아래로 밀려 bottom 이 화면 밖(바닥 아래)으로 나가는 것 보정.
    // 실제 배치된 top 을 읽어 height 를 줄여 창 bottom = 화면 하단(=캐릭터 바닥)에 맞춘다.
    if let Ok(actual) = win.outer_position() {
        let actual_top = actual.y as f64 / scale;
        let h = (p.y + s.height) - actual_top;
        if h > 100.0 && (h - s.height).abs() > 0.5 {
            let _ = win.set_size(LogicalSize::new(s.width, h));
            let _ = win.set_position(LogicalPosition::new(p.x, actual_top));
        }
    }
}

/// Windows: 모니터 rect 가 물리픽셀 그대로라 직접 지정이 정확하다.
/// (논리좌표로 주면 tauri 가 "이동 전 창 scale" 로 환산해 혼합 DPI 에서 어긋남)
#[cfg(not(target_os = "macos"))]
fn fit_to_monitor(win: &WebviewWindow, m: &Monitor) {
    let _ = win.set_position(*m.position());
    let _ = win.set_size(*m.size());
}

/// idx 번째(정렬순) 모니터에 배치. 실제 적용된 인덱스를 반환.
fn apply_display(win: &WebviewWindow, idx: usize) -> usize {
    let ms = sorted_monitors(win);
    if ms.is_empty() {
        return 0;
    }
    let i = idx.min(ms.len() - 1);
    fit_to_monitor(win, &ms[i]);
    i
}

#[tauri::command]
fn set_click_through(window: WebviewWindow, through: bool) {
    let _ = window.set_ignore_cursor_events(through);
}

/// 프론트에서 OS 분기(자동 업데이트는 Windows 만) 용
#[tauri::command]
fn get_os() -> &'static str {
    std::env::consts::OS
}

#[tauri::command]
fn place_on_display(window: WebviewWindow, state: State<'_, AppState>, idx: usize) {
    let i = apply_display(&window, idx);
    *state.display_index.lock().unwrap() = i;
}

/// 캐릭터 잡기/놓기 알림 — 잡혀있는 동안 커서 폴링이 크로스모니터 창 이동을 수행
/// (main.swift 의 mouseDragged→ensureScreen 포팅)
#[tauri::command]
fn set_grabbed(state: State<'_, AppState>, grabbed: bool) {
    state.grabbed.store(grabbed, Ordering::Relaxed);
    #[cfg(debug_assertions)]
    println!("[dp] grabbed={}", grabbed);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState {
            display_index: Mutex::new(0),
            grabbed: AtomicBool::new(false),
        })
        .invoke_handler(tauri::generate_handler![
            set_click_through,
            place_on_display,
            get_os,
            set_grabbed
        ])
        .setup(|app| {
            let win = app.get_webview_window("main").expect("main window missing");
            // 데스크톱 위 클릭통과 오버레이 (커서가 캐릭터 위일 때만 프론트가 해제)
            let _ = win.set_ignore_cursor_events(true);

            // 시작 배치: 0번(가장 왼쪽) 모니터 전체. (저장된 디스플레이는 JS 가 store 읽어 교정)
            let idx = apply_display(&win, 0);
            *app.state::<AppState>().display_index.lock().unwrap() = idx;

            // 창 레벨을 Dock 위로 (macOS) — 하단 Dock 에 가려지지 않고 그 위를 등반
            #[cfg(target_os = "macos")]
            if let Ok(ns) = win.ns_window() {
                platform::raise_above_dock(ns);
            }
            // Dock 감지에 필요한 접근성 권한 요청 (main.swift 와 동일)
            #[cfg(target_os = "macos")]
            platform::prompt_accessibility();

            // ── 오디오 출력 감지 → 변화 시 프론트로 emit (main.swift audioTimer 0.4s 포팅) ──
            let audio_handle = app.handle().clone();
            std::thread::spawn(move || {
                let mut last = false;
                loop {
                    let active = platform::audio_output_active();
                    if active != last {
                        last = active;
                        let _ = audio_handle.emit("audio-active", active);
                    }
                    std::thread::sleep(Duration::from_millis(400));
                }
            });

            // ── Dock/작업표시줄 감지 → 매초 프론트로 emit (main.swift dockTimer 1s 포팅) ──
            let dock_handle = app.handle().clone();
            std::thread::spawn(move || loop {
                if let Some(win) = dock_handle.get_webview_window("main") {
                    if let (Ok(op), Ok(scale), Ok(sz)) =
                        (win.outer_position(), win.scale_factor(), win.inner_size())
                    {
                        let rect = platform::dock_rect(
                            op.x as f64 / scale,
                            op.y as f64 / scale,
                            sz.width as f64 / scale,
                            sz.height as f64 / scale,
                        );
                        let _ = win.emit("dock", rect);
                    }
                }
                std::thread::sleep(Duration::from_millis(1000));
            });

            // ── 메뉴바 트레이 ──
            let about_i = MenuItem::with_id(app, "about", "DancingPet 정보 (About)", true, None::<&str>)?;
            let char_hdr = MenuItem::with_id(app, "char_hdr", "캐릭터 (Character)", false, None::<&str>)?;
            let waabi_i = CheckMenuItem::with_id(app, "char_waabi", "  와비 (Waabi)", true, true, None::<&str>)?;
            let move_i = MenuItem::with_id(app, "move_display", "다음 화면으로 이동", true, None::<&str>)?;
            let quit_i = MenuItem::with_id(app, "quit", "종료 (Quit)", true, Some("Cmd+Q"))?;
            let sep1 = PredefinedMenuItem::separator(app)?;
            let sep2 = PredefinedMenuItem::separator(app)?;
            let sep3 = PredefinedMenuItem::separator(app)?;

            let menu = Menu::new(app)?;
            menu.append(&about_i)?;
            menu.append(&sep1)?;
            menu.append(&char_hdr)?;
            menu.append(&waabi_i)?;
            menu.append(&sep2)?;
            menu.append(&move_i)?;
            menu.append(&sep3)?;
            menu.append(&quit_i)?;

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("DancingPet")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "about" => {
                        let _ = app.emit("menu-about", ());
                    }
                    "move_display" => {
                        if let Some(win) = app.get_webview_window("main") {
                            let state = app.state::<AppState>();
                            let mut idx = state.display_index.lock().unwrap();
                            let ms = sorted_monitors(&win);
                            if !ms.is_empty() {
                                let next = (*idx + 1) % ms.len();
                                fit_to_monitor(&win, &ms[next]);
                                *idx = next;
                                let _ = app.emit("display-changed", next);
                            }
                        }
                    }
                    _ => {}
                })
                .build(app)?;

            // ── 커서 폴링 → 창-로컬(CSS px) 좌표를 프론트로 emit (클릭통과 토글용) ──
            // 드래그(잡힘) 중엔 커서가 있는 모니터로 창을 따라 이동시켜 크로스모니터
            // 드래그를 지원 (main.swift mouseDragged→ensureScreen 과 동일 동작)
            let handle = app.handle().clone();
            std::thread::spawn(move || loop {
                if let Some(win) = handle.get_webview_window("main") {
                    let state = handle.state::<AppState>();
                    if state.grabbed.load(Ordering::Relaxed) {
                        let ms = sorted_monitors(&win);
                        if let Some(idx) = monitor_under_cursor(&win, &ms) {
                            // 락을 fit_to_monitor(메인스레드 대기) 밖에서 짧게만 잡는다
                            let moved = {
                                let mut cur = state.display_index.lock().unwrap();
                                if idx != *cur {
                                    *cur = idx;
                                    true
                                } else {
                                    false
                                }
                            };
                            if moved {
                                fit_to_monitor(&win, &ms[idx]);
                                let _ = win.emit("display-changed", idx);
                                #[cfg(debug_assertions)]
                                println!("[dp] drag display -> {}", idx);
                            }
                        }
                    }
                    if let Some((lx, ly)) = cursor_local(&win) {
                        let _ = win.emit("cursor", (lx, ly));
                    }
                }
                std::thread::sleep(Duration::from_millis(40));
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

