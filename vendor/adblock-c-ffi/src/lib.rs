use adblock::lists::FilterSet;
use adblock::Engine;
use std::ffi::c_char;
use std::ptr;
use std::slice;
use std::str;

#[repr(C)]
pub struct AdblockResult {
    pub matched: bool,
    pub important: bool,
    pub has_exception: bool,
    pub redirect: *mut c_char,
    pub rewritten_url: *mut c_char,
}

impl Default for AdblockResult {
    fn default() -> Self {
        Self {
            matched: false,
            important: false,
            has_exception: false,
            redirect: ptr::null_mut(),
            rewritten_url: ptr::null_mut(),
        }
    }
}

#[no_mangle]
pub extern "C" fn adblock_create_engine() -> *mut Engine {
    let engine = Engine::from_rules(std::iter::empty::<String>(), Default::default());
    Box::into_raw(Box::new(engine))
}

#[no_mangle]
pub extern "C" fn adblock_create_engine_with_rules(
    rules: *const c_char,
    rules_len: usize,
) -> *mut Engine {
    if rules.is_null() || rules_len == 0 {
        return ptr::null_mut();
    }

    let rules_slice = unsafe { slice::from_raw_parts(rules as *const u8, rules_len) };
    let rules_str = match str::from_utf8(rules_slice) {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    let engine = Engine::from_rules(std::iter::once(rules_str.to_string()), Default::default());
    Box::into_raw(Box::new(engine))
}

#[no_mangle]
pub extern "C" fn adblock_add_filter_list(
    engine: *mut Engine,
    rules: *const c_char,
    rules_len: usize,
) -> bool {
    if engine.is_null() || rules.is_null() || rules_len == 0 {
        return false;
    }

    let rules_slice = unsafe { slice::from_raw_parts(rules as *const u8, rules_len) };
    let rules_str = match str::from_utf8(rules_slice) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let mut filter_set = FilterSet::new(false);
    let _ = filter_set.add_filter_list(rules_str, Default::default());
    let engine = unsafe { &mut *engine };
    let new_engine = Engine::from_filter_set(filter_set, true);
    *engine = new_engine;
    true
}

#[no_mangle]
pub extern "C" fn adblock_matches(
    engine: *const Engine,
    url: *const c_char,
    hostname: *const c_char,
    source_hostname: *const c_char,
    request_type: *const c_char,
    third_party: bool,
) -> AdblockResult {
    if engine.is_null() || url.is_null() || hostname.is_null() || request_type.is_null() {
        return AdblockResult::default();
    }

    let url_str = match ptr_to_string(url) {
        Some(s) => s,
        None => return AdblockResult::default(),
    };
    let hostname_str = match ptr_to_string(hostname) {
        Some(s) => s,
        None => return AdblockResult::default(),
    };
    let source_hostname_str = if source_hostname.is_null() {
        String::new()
    } else {
        match ptr_to_string(source_hostname) {
            Some(s) => s,
            None => String::new(),
        }
    };
    let request_type_str = match ptr_to_string(request_type) {
        Some(s) => s,
        None => return AdblockResult::default(),
    };

    let engine = unsafe { &*engine };

    let request = adblock::request::Request::preparsed(
        &url_str,
        &hostname_str,
        &source_hostname_str,
        &request_type_str,
        third_party,
    );

    let result = engine.check_network_request_subset(&request, false, false);

    let mut adblock_result = AdblockResult::default();
    adblock_result.matched = result.matched;
    adblock_result.important = result.important;
    adblock_result.has_exception = result.exception.is_some();

    if let Some(redirect) = result.redirect {
        adblock_result.redirect = alloc_c_string(&redirect);
    }
    if let Some(rewritten) = result.rewritten_url {
        adblock_result.rewritten_url = alloc_c_string(&rewritten);
    }

    adblock_result
}

#[no_mangle]
pub extern "C" fn adblock_get_cosmetic_filters(
    engine: *const Engine,
    url: *const c_char,
) -> *mut c_char {
    if engine.is_null() || url.is_null() {
        return ptr::null_mut();
    }

    let url_str = match ptr_to_string(url) {
        Some(s) => s,
        None => return ptr::null_mut(),
    };

    let engine = unsafe { &*engine };
    let cosmetic_resources = engine.url_cosmetic_resources(&url_str);
    let cosmetic_json = serde_json::to_string(&cosmetic_resources).unwrap_or_default();

    alloc_c_string(&cosmetic_json)
}

#[no_mangle]
pub extern "C" fn adblock_destroy_engine(engine: *mut Engine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

#[no_mangle]
pub extern "C" fn adblock_free_string(s: *mut c_char) {
    _ = s;
}

fn ptr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe {
        let mut len = 0;
        let mut p = ptr;
        while *p != 0 {
            len += 1;
            p = p.offset(1);
        }
        if len == 0 {
            return Some(String::new());
        }
        let slice = slice::from_raw_parts(ptr as *const u8, len);
        str::from_utf8(slice).ok().map(|s| s.to_string())
    }
}

fn alloc_c_string(s: &str) -> *mut c_char {
    let mut vec = s.as_bytes().to_vec();
    vec.push(0);
    let ptr = vec.as_mut_ptr();
    std::mem::forget(vec);
    ptr as *mut c_char
}
