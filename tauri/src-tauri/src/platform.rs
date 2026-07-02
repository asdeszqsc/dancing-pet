// OS 네이티브 기능 — 오디오 출력 감지, 창 레벨(Dock 위), Dock/작업표시줄 감지.
// macOS 는 main.swift 의 AudioMonitor / window.level / readDock(AX) 를 포팅.
// Windows 는 Phase 4 에서 WASAPI / Shell_TrayWnd 로 구현 (그 환경에서 컴파일 검증).

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

    /// 실제 Dock rect → 창-로컬(바닥 기준 CSS px). win_* 는 창의 논리(CSS) 좌표/크기.
    pub fn dock_rect(win_x: f64, win_y: f64, win_w: f64, win_h: f64) -> Option<DockRect> {
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

// ══════════════════════════ 기타 OS (Windows 등) — Phase 4 에서 구현 ══════════════════════════
#[cfg(not(target_os = "macos"))]
mod imp {
    use super::*;

    pub fn audio_output_active() -> bool {
        false // TODO(Phase 4): Windows WASAPI IAudioMeterInformation::GetPeakValue
    }
    pub fn raise_above_dock(_ns_window: *mut c_void) {}
    pub fn prompt_accessibility() {}
    pub fn dock_rect(_x: f64, _y: f64, _w: f64, _h: f64) -> Option<DockRect> {
        None // TODO(Phase 4): Windows Shell_TrayWnd rect
    }
}

pub use imp::{audio_output_active, dock_rect, prompt_accessibility, raise_above_dock};
