// OS 네이티브 기능 — 오디오 출력 감지, 창 레벨(Dock 위), Dock/작업표시줄 감지.
// macOS 는 main.swift 의 AudioMonitor / window.level / readDock(AX) 를 포팅.
// Windows 는 Shell_TrayWnd 로 작업표시줄 감지 (오디오 WASAPI 는 TODO).
//
// dock_rect 의 win_* 인자는 창의 물리 px (outer_position/inner_size 그대로) + scale.
// 반환은 창-로컬 CSS px — 각 OS 구현이 자기 좌표계에 맞게 변환한다.

use std::os::raw::c_void;

/// Dock/작업표시줄 사각형 (창-로컬 CSS px, 바닥 기준 y = 발이 설 높이). 없으면 None.
#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockRect {
    pub left: f64,
    pub right: f64,
    pub top_y: f64,
}

const DOCK_FEET_INSET: f64 = 8.0; // main.swift kDockFeetInset — 발을 살짝 박히게

/// 작업표시줄 후보 rect([l,t,r,b] 물리 px, 창과 같은 가상 스크린 좌표)들에서
/// 이 창의 바닥면(DockRect)을 계산 — Windows 구현의 필터/변환 로직.
/// OS 독립 순수 함수로 분리해 macOS 에서도 단위테스트한다.
/// 필터: 이 창(모니터)과 교차 · 가로형 · 창 하단 절반 · 자동숨김(노출 수 px) 제외.
#[allow(dead_code)]
fn taskbar_dock_rect(
    bars: &[[f64; 4]],
    win_x: f64,
    win_y: f64,
    win_w: f64,
    win_h: f64,
    scale: f64,
) -> Option<DockRect> {
    let (wl, wt, wr, wb) = (win_x, win_y, win_x + win_w, win_y + win_h);
    let mut best: Option<(f64, f64, f64)> = None; // (left, right, top) 물리
    for &[l, t, r, b] in bars {
        if r <= wl || l >= wr || b <= wt || t >= wb {
            continue; // 이 창(모니터)과 안 겹침 — 옆 모니터의 작업표시줄
        }
        if (r - l) < (b - t) {
            continue; // 좌/우 세로 배치 — 바닥과 무관
        }
        if t < wt + win_h * 0.5 {
            continue; // 상단 배치 — 바닥과 무관
        }
        let cand = (l.max(wl), r.min(wr), t);
        if best.map_or(true, |(_, _, bt)| cand.2 < bt) {
            best = Some(cand);
        }
    }
    let (l, r, t) = best?;
    let height_css = (wb - t) / scale;
    if height_css <= DOCK_FEET_INSET + 4.0 {
        return None; // 자동 숨김 상태(화면 밖으로 슬라이드) 등 — 바닥 취급 안 함
    }
    Some(DockRect {
        left: (l - win_x) / scale,
        right: (r - win_x) / scale,
        top_y: height_css - DOCK_FEET_INSET,
    })
}

// ══════════════════════════ macOS ══════════════════════════
#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use core_foundation::array::{CFArray, CFArrayRef};
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};

    type CFDictionaryRef = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGPointC {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGSizeC {
        w: f64,
        h: f64,
    }
    #[derive(Clone, Copy)]
    struct RectC {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    }

    const AX_VALUE_CGPOINT: u32 = 1; // kAXValueTypeCGPoint
    const AX_VALUE_CGSIZE: u32 = 2; // kAXValueTypeCGSize

    // ── CoreAudio: 기본 출력 장치가 재생 중인지 (AudioMonitor 포팅) ──
    #[repr(C)]
    struct AudioObjectPropertyAddress {
        m_selector: u32,
        m_scope: u32,
        m_element: u32,
    }
    #[link(name = "CoreAudio", kind = "framework")]
    extern "C" {
        fn AudioObjectGetPropertyData(
            in_object: u32,
            in_address: *const AudioObjectPropertyAddress,
            in_qualifier_data_size: u32,
            in_qualifier_data: *const c_void,
            io_data_size: *mut u32,
            out_data: *mut c_void,
        ) -> i32;
    }
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> CFArrayRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFDictionaryGetValue(d: CFDictionaryRef, key: *const c_void) -> *const c_void;
        fn CFNumberGetValue(number: *const c_void, the_type: i32, value_ptr: *mut c_void) -> u8;
        fn CFRelease(cf: *const c_void);
    }
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXUIElementCreateApplication(pid: i32) -> *const c_void;
        fn AXUIElementCopyAttributeValue(
            element: *const c_void,
            attribute: *const c_void,
            value: *mut *const c_void,
        ) -> i32;
        fn AXValueGetValue(value: *const c_void, the_type: u32, value_ptr: *mut c_void) -> u8;
        fn AXIsProcessTrusted() -> u8;
        fn AXIsProcessTrustedWithOptions(options: *const c_void) -> u8;
    }

    const SYSTEM_OBJECT: u32 = 1;
    const DEFAULT_OUTPUT_DEVICE: u32 = 0x644f_7574; // 'dOut'
    const SCOPE_GLOBAL: u32 = 0x676c_6f62; // 'glob'
    const IS_RUNNING_SOMEWHERE: u32 = 0x676f_6e65; // 'gone'
    const ELEMENT_MAIN: u32 = 0;

    pub fn audio_output_active() -> bool {
        unsafe {
            let mut device_id: u32 = 0;
            let mut size = std::mem::size_of::<u32>() as u32;
            let addr = AudioObjectPropertyAddress {
                m_selector: DEFAULT_OUTPUT_DEVICE,
                m_scope: SCOPE_GLOBAL,
                m_element: ELEMENT_MAIN,
            };
            let st = AudioObjectGetPropertyData(
                SYSTEM_OBJECT,
                &addr,
                0,
                std::ptr::null(),
                &mut size,
                &mut device_id as *mut _ as *mut c_void,
            );
            if st != 0 || device_id == 0 {
                return false;
            }
            let mut running: u32 = 0;
            let mut rsize = std::mem::size_of::<u32>() as u32;
            let raddr = AudioObjectPropertyAddress {
                m_selector: IS_RUNNING_SOMEWHERE,
                m_scope: SCOPE_GLOBAL,
                m_element: ELEMENT_MAIN,
            };
            let st2 = AudioObjectGetPropertyData(
                device_id,
                &raddr,
                0,
                std::ptr::null(),
                &mut rsize,
                &mut running as *mut _ as *mut c_void,
            );
            if st2 != 0 {
                return false;
            }
            running != 0
        }
    }

    // ── 창 레벨을 Dock 위로 (CGWindowLevelForKey(.dockWindow) + 1) ──
    pub fn raise_above_dock(ns_window: *mut c_void) {
        if ns_window.is_null() {
            return;
        }
        unsafe {
            extern "C" {
                fn CGWindowLevelForKey(key: i32) -> i32;
            }
            const DOCK_LEVEL_KEY: i32 = 7; // kCGDockWindowLevelKey
            let level = CGWindowLevelForKey(DOCK_LEVEL_KEY) + 1;
            let ns: *mut objc2::runtime::AnyObject = ns_window as *mut _;
            let _: () = objc2::msg_send![ns, setLevel: level as isize];
        }
    }

    /// 접근성 권한 요청 (시스템 다이얼로그) — main.swift AXIsProcessTrustedWithOptions 포팅
    pub fn prompt_accessibility() {
        unsafe {
            let key = CFString::from_static_string("AXTrustedCheckOptionPrompt");
            let val = CFBoolean::true_value();
            let dict = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), val.as_CFType())]);
            AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef() as *const c_void);
        }
    }

    // ── Dock 프로세스 PID (CGWindowList 의 kCGWindowOwnerPID) ──
    fn dock_pid() -> Option<i32> {
        const ON_SCREEN_ONLY: u32 = 1;
        unsafe {
            let arr_ref = CGWindowListCopyWindowInfo(ON_SCREEN_ONLY, 0);
            if arr_ref.is_null() {
                return None;
            }
            let arr: CFArray<CFType> = CFArray::wrap_under_create_rule(arr_ref);
            let owner_key = CFString::from_static_string("kCGWindowOwnerName");
            let pid_key = CFString::from_static_string("kCGWindowOwnerPID");
            for item in arr.iter() {
                let d = item.as_CFTypeRef() as CFDictionaryRef;
                let ov = CFDictionaryGetValue(d, owner_key.as_concrete_TypeRef() as *const c_void);
                if ov.is_null() {
                    continue;
                }
                if CFString::wrap_under_get_rule(ov as CFStringRef).to_string() != "Dock" {
                    continue;
                }
                let pv = CFDictionaryGetValue(d, pid_key.as_concrete_TypeRef() as *const c_void);
                if pv.is_null() {
                    continue;
                }
                let mut pid: i32 = 0;
                // kCFNumberSInt32Type = 3
                if CFNumberGetValue(pv, 3, &mut pid as *mut _ as *mut c_void) != 0 && pid > 0 {
                    return Some(pid);
                }
            }
            None
        }
    }

    // ── AX 헬퍼 ──
    unsafe fn ax_copy(el: *const c_void, attr: &str) -> Option<*const c_void> {
        let a = CFString::new(attr);
        let mut out: *const c_void = std::ptr::null();
        let err = AXUIElementCopyAttributeValue(el, a.as_concrete_TypeRef() as *const c_void, &mut out);
        if err == 0 && !out.is_null() {
            Some(out)
        } else {
            None
        }
    }

    unsafe fn ax_role(el: *const c_void) -> Option<String> {
        let v = ax_copy(el, "AXRole")?;
        Some(CFString::wrap_under_create_rule(v as CFStringRef).to_string())
    }

    unsafe fn ax_frame(el: *const c_void) -> Option<RectC> {
        let pos_v = ax_copy(el, "AXPosition")?;
        let size_v = ax_copy(el, "AXSize")?;
        let mut p = CGPointC { x: 0.0, y: 0.0 };
        let mut s = CGSizeC { w: 0.0, h: 0.0 };
        let ok1 = AXValueGetValue(pos_v, AX_VALUE_CGPOINT, &mut p as *mut _ as *mut c_void);
        let ok2 = AXValueGetValue(size_v, AX_VALUE_CGSIZE, &mut s as *mut _ as *mut c_void);
        CFRelease(pos_v);
        CFRelease(size_v);
        if ok1 == 0 || ok2 == 0 {
            return None;
        }
        Some(RectC {
            x: p.x,
            y: p.y,
            w: s.w,
            h: s.h,
        })
    }

    /// AXList 요소들의 프레임 수집 (depth<=3) — main.swift collectLists 포팅
    unsafe fn collect_list_frames(el: *const c_void, depth: i32, out: &mut Vec<RectC>) {
        if depth > 3 {
            return;
        }
        if let Some(role) = ax_role(el) {
            if role == "AXList" {
                if let Some(f) = ax_frame(el) {
                    out.push(f);
                }
            }
        }
        if let Some(kids_v) = ax_copy(el, "AXChildren") {
            let kids: CFArray<CFType> = CFArray::wrap_under_create_rule(kids_v as CFArrayRef);
            for k in kids.iter() {
                collect_list_frames(k.as_CFTypeRef() as *const c_void, depth + 1, out);
            }
        }
    }

    /// 실제 Dock rect → 창-로컬(바닥 기준 CSS px). win_* 물리 px 를 논리(포인트)로
    /// 변환해 AX 프레임(포인트)과 비교한다.
    pub fn dock_rect(win_x: f64, win_y: f64, win_w: f64, win_h: f64, scale: f64) -> Option<DockRect> {
        let (win_x, win_y, win_w, win_h) = (win_x / scale, win_y / scale, win_w / scale, win_h / scale);
        unsafe {
            if AXIsProcessTrusted() == 0 {
                return None; // 접근성 권한 없음
            }
            let pid = dock_pid()?;
            let app = AXUIElementCreateApplication(pid);
            if app.is_null() {
                return None;
            }
            let mut frames: Vec<RectC> = Vec::new();
            collect_list_frames(app, 0, &mut frames);
            CFRelease(app);

            // main.swift readDock 필터: 얇은 스트립 · 전체폭 아님 · 하단 · 이 창(디스플레이) 안
            let mut min_x = f64::MAX;
            let mut max_x = f64::MIN;
            let mut top = f64::MAX;
            for r in &frames {
                if r.h < 10.0 || r.h > 200.0 {
                    continue;
                }
                if r.w >= win_w * 0.99 {
                    continue;
                }
                if (r.y - win_y) < win_h * 0.5 {
                    continue; // 하단 절반만
                }
                let lx = r.x - win_x;
                let rx = r.x + r.w - win_x;
                if rx < 0.0 || lx > win_w {
                    continue; // 이 창의 가로 범위 밖
                }
                min_x = min_x.min(r.x);
                max_x = max_x.max(r.x + r.w);
                top = top.min(r.y);
            }
            if min_x > max_x {
                return None;
            }
            let left = min_x - win_x;
            let right = max_x - win_x;
            let dock_h = win_h - (top - win_y);
            if dock_h <= 20.0 {
                return None;
            }
            let center = (left + right) / 2.0;
            if center < 0.0 || center > win_w {
                return None;
            }
            Some(DockRect {
                left,
                right,
                top_y: dock_h - DOCK_FEET_INSET,
            })
        }
    }
}

// ══════════════════════════ Windows ══════════════════════════
#[cfg(windows)]
mod imp {
    use super::*;
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, FindWindowW, GetWindowRect, IsWindowVisible,
    };

    pub fn audio_output_active() -> bool {
        false // TODO: WASAPI IAudioMeterInformation::GetPeakValue
    }
    pub fn raise_above_dock(_ns_window: *mut c_void) {}
    pub fn prompt_accessibility() {}

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// 작업표시줄(주: Shell_TrayWnd, 보조 모니터: Shell_SecondaryTrayWnd) rect 수집
    /// → taskbar_dock_rect 로 필터/변환. GetWindowRect 는 가상 스크린 물리 px
    /// (per-monitor DPI aware 프로세스) — 창 outer_position 과 같은 좌표계.
    pub fn dock_rect(win_x: f64, win_y: f64, win_w: f64, win_h: f64, scale: f64) -> Option<DockRect> {
        let mut bars: Vec<[f64; 4]> = Vec::new();
        let mut push = |hwnd: HWND| unsafe {
            if hwnd.is_null() || IsWindowVisible(hwnd) == 0 {
                return;
            }
            let mut r = RECT {
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
            };
            if GetWindowRect(hwnd, &mut r) != 0 {
                bars.push([r.left as f64, r.top as f64, r.right as f64, r.bottom as f64]);
            }
        };
        unsafe {
            let primary = wide("Shell_TrayWnd");
            push(FindWindowW(primary.as_ptr(), std::ptr::null()));
            let secondary = wide("Shell_SecondaryTrayWnd");
            let mut h: HWND = std::ptr::null_mut();
            loop {
                h = FindWindowExW(std::ptr::null_mut(), h, secondary.as_ptr(), std::ptr::null());
                if h.is_null() {
                    break;
                }
                push(h);
            }
        }
        taskbar_dock_rect(&bars, win_x, win_y, win_w, win_h, scale)
    }
}

// ══════════════════════════ 기타 OS (Linux 등) ══════════════════════════
#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    use super::*;

    pub fn audio_output_active() -> bool {
        false
    }
    pub fn raise_above_dock(_ns_window: *mut c_void) {}
    pub fn prompt_accessibility() {}
    pub fn dock_rect(_x: f64, _y: f64, _w: f64, _h: f64, _scale: f64) -> Option<DockRect> {
        None
    }
}

pub use imp::{audio_output_active, dock_rect, prompt_accessibility, raise_above_dock};

// ══════════════════════════ 테스트 (taskbar_dock_rect 는 OS 독립) ══════════════════════════
#[cfg(test)]
mod tests {
    use super::*;

    // 1920x1080 모니터(가상 스크린 원점), 48px 작업표시줄, 100% 스케일
    #[test]
    fn bottom_taskbar_100pct() {
        let r = taskbar_dock_rect(&[[0.0, 1032.0, 1920.0, 1080.0]], 0.0, 0.0, 1920.0, 1080.0, 1.0)
            .expect("bottom taskbar should be detected");
        assert_eq!(r.left, 0.0);
        assert_eq!(r.right, 1920.0);
        assert!((r.top_y - (48.0 - DOCK_FEET_INSET)).abs() < 0.01);
    }

    // 150% 스케일: 물리 2880x1620 (논리 1920x1080), 작업표시줄 물리 72px → CSS 48px
    #[test]
    fn bottom_taskbar_150pct() {
        let r = taskbar_dock_rect(&[[0.0, 1548.0, 2880.0, 1620.0]], 0.0, 0.0, 2880.0, 1620.0, 1.5)
            .expect("scaled taskbar should be detected");
        assert!((r.top_y - (48.0 - DOCK_FEET_INSET)).abs() < 0.01);
        assert!((r.right - 1920.0).abs() < 0.01);
    }

    // 두 번째 모니터(창이 x=1920..3840)에서 보조 작업표시줄 감지 — 창-로컬 좌표로 변환
    #[test]
    fn secondary_monitor_taskbar() {
        let r = taskbar_dock_rect(
            &[[1920.0, 1032.0, 3840.0, 1080.0]],
            1920.0, 0.0, 1920.0, 1080.0, 1.0,
        )
        .expect("secondary taskbar should be detected");
        assert_eq!(r.left, 0.0);
        assert_eq!(r.right, 1920.0);
    }

    #[test]
    fn top_taskbar_ignored() {
        assert!(taskbar_dock_rect(&[[0.0, 0.0, 1920.0, 48.0]], 0.0, 0.0, 1920.0, 1080.0, 1.0).is_none());
    }

    #[test]
    fn vertical_taskbar_ignored() {
        assert!(taskbar_dock_rect(&[[0.0, 0.0, 62.0, 1080.0]], 0.0, 0.0, 1920.0, 1080.0, 1.0).is_none());
    }

    // 옆 모니터의 작업표시줄은 이 창과 안 겹치므로 무시
    #[test]
    fn other_monitor_bar_ignored() {
        assert!(taskbar_dock_rect(
            &[[1920.0, 1032.0, 3840.0, 1080.0]],
            0.0, 0.0, 1920.0, 1080.0, 1.0
        )
        .is_none());
    }

    // 자동 숨김(화면 밖으로 슬라이드, 2px 노출)은 바닥 취급 안 함
    #[test]
    fn autohidden_taskbar_ignored() {
        assert!(taskbar_dock_rect(
            &[[0.0, 1078.0, 1920.0, 1080.0]],
            0.0, 0.0, 1920.0, 1080.0, 1.0
        )
        .is_none());
    }
}
