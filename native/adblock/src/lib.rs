//! Shared Brave engine. Android uses JNI; macOS uses the same C ABI and engine
//! to compile WebKit content rules and select document-start scriptlets.
use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

pub const ENGINE_VERSION: &str = "0.13.6";
static STATE: OnceLock<Mutex<Option<State>>> = OnceLock::new();

#[derive(Deserialize)]
struct List {
    text: String,
    #[serde(default)]
    platforms: Vec<String>,
    #[serde(default)]
    permission: u8,
}

#[derive(Deserialize)]
struct Bundle {
    schema: u32,
    engine_version: String,
    version: u64,
    lists: Vec<List>,
    resources: Vec<Resource>,
}

struct State {
    engine: Engine,
    version: u64,
    script: String,
    webkit: Value,
}

// uAssets lists contain conditional branches for browser capabilities. Parsing
// both branches as ordinary rules can cancel exceptions or break playback.
fn condition(expression: &str, platform: &str) -> bool {
    let expression = expression.trim();
    if let Some((a, b)) = expression.split_once("||") {
        return condition(a, platform) || condition(b, platform);
    }
    if let Some((a, b)) = expression.split_once("&&") {
        return condition(a, platform) && condition(b, platform);
    }
    if let Some(rest) = expression.strip_prefix('!') {
        return !condition(rest, platform);
    }
    match expression.trim_matches(|c| c == '(' || c == ')') {
        "true" | "cap_ipaddress" | "cap_scriptlet_injection" | "cap_redirect" => true,
        "env_chromium" | "env_chromium_android" | "env_mobile" => platform == "android",
        "env_safari" => platform == "macos",
        _ => false,
    }
}

fn preprocess(text: &str, platform: &str) -> Result<String, String> {
    let mut stack = vec![true];
    let mut branches = Vec::new();
    let mut output = String::with_capacity(text.len());
    for line in text.lines() {
        if let Some(expression) = line.strip_prefix("!#if ") {
            let yes = condition(expression, platform);
            branches.push(yes);
            stack.push(*stack.last().unwrap() && yes);
        } else if line.trim() == "!#else" {
            let yes = branches.last_mut().ok_or("unmatched filter #else")?;
            *yes = !*yes;
            let parent = stack[stack.len() - 2];
            *stack.last_mut().unwrap() = parent && *yes;
        } else if line.trim() == "!#endif" {
            if stack.len() == 1 {
                return Err("unmatched filter #endif".into());
            }
            stack.pop();
            branches.pop();
        } else if *stack.last().unwrap() {
            if line.starts_with("!#include") {
                return Err("filter includes must be resolved by the bundle updater".into());
            }
            output.push_str(line);
            output.push('\n');
        }
    }
    if stack.len() != 1 {
        return Err("unterminated filter condition".into());
    }
    Ok(output)
}

impl State {
    fn build(contents: &str, platform: &str) -> Result<Self, String> {
        let bundle: Bundle = serde_json::from_str(contents).map_err(|e| e.to_string())?;
        if bundle.schema != 1 || bundle.engine_version != ENGINE_VERSION || bundle.lists.is_empty()
        {
            return Err("unsupported or empty Brave filter bundle".into());
        }
        let mut set = FilterSet::new(false);
        let mut safari = FilterSet::new(true);
        for list in bundle.lists {
            if !list.platforms.is_empty() && !list.platforms.iter().any(|p| p == platform) {
                continue;
            }
            let text = preprocess(&list.text, platform)?;
            let options = ParseOptions {
                permissions: PermissionMask::from_bits(list.permission),
                ..Default::default()
            };
            if platform == "macos" {
                safari.add_filter_list(
                    text.clone(),
                    ParseOptions {
                        rule_types: RuleTypes::NetworkOnly,
                        ..options
                    },
                );
            }
            set.add_filter_list(text, options);
        }
        let mut engine = Engine::new_with_filter_set(set);
        engine.use_resources(bundle.resources);
        let webkit = if platform == "macos" {
            let (rules, converted) = safari
                .into_content_blocking()
                .map_err(|_| "WebKit conversion failed")?;
            json!({"rules": rules, "converted": converted.len()})
        } else {
            Value::Null
        };
        // Inline the actual engine-selected YouTube scriptlets. They execute
        // before site code without depending on eval or a site's CSP policy.
        let mut injections = String::new();
        for host in [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "youtube-nocookie.com",
            "www.youtube-nocookie.com",
        ] {
            let page = engine.url_cosmetic_resources(&format!("https://{host}/"));
            injections.push_str(&format!("if (location.hostname === {}) {{ try {{\n{}\n}} catch (_) {{}} preloaded = true; preloadedPage = {}; }}\n",
                json!(host), page.injected_script, json!({"selectors":page.hide_selectors,"generichide":page.generichide})));
        }
        let script = include_str!("../../../assets/js/brave_adblock.js")
            .replace("/* CUPITOR_BRAVE_SCRIPTLETS */", &injections);
        Ok(Self {
            engine,
            version: bundle.version,
            script,
            webkit,
        })
    }

    fn query(&self, input: &Value) -> Value {
        let string = |key| input.get(key).and_then(Value::as_str).unwrap_or("");
        match string("op") {
            "status" => json!({"ready": true, "engine": ENGINE_VERSION, "version": self.version}),
            "script" => json!({"script": self.script}),
            "webkit" => self.webkit.clone(),
            "network" => match Request::new(
                input
                    .get("target")
                    .and_then(Value::as_str)
                    .unwrap_or(string("url")),
                input
                    .get("source")
                    .and_then(Value::as_str)
                    .unwrap_or(string("url")),
                string("type"),
                string("method"),
            ) {
                Ok(request) => {
                    let r = self.engine.check_network_request(&request);
                    json!({"blocked": r.should_block(), "redirect": r.redirect, "rewritten": r.rewritten_url,
                        "exception": r.exception.is_some()})
                }
                Err(_) => json!({"blocked": false}),
            },
            "page" => {
                let page = self.engine.url_cosmetic_resources(string("url"));
                json!({"selectors": page.hide_selectors, "exceptions": page.exceptions,
                    "generichide": page.generichide,
                    "js": if input.get("scriptlets") == Some(&Value::Bool(false)) { String::new() } else { page.injected_script }})
            }
            "selectors" => {
                let values = |key| -> Vec<String> {
                    input
                        .get(key)
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .take(4096)
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                };
                let page = self.engine.url_cosmetic_resources(string("url"));
                let selectors = if page.generichide {
                    vec![]
                } else {
                    self.engine.hidden_class_id_selectors(
                        values("classes"),
                        values("ids"),
                        &page.exceptions,
                    )
                };
                json!({"selectors": selectors})
            }
            _ => json!({"error": "unknown Brave operation"}),
        }
    }
}

fn initialize(directory: &str, platform: &str) -> Value {
    let result = std::fs::read_to_string(Path::new(directory).join("bundle.json"))
        .map_err(|e| e.to_string())
        .and_then(|text| State::build(&text, platform));
    match result {
        Ok(state) => {
            let status = state.query(&json!({"op": "status"}));
            match STATE.get_or_init(|| Mutex::new(None)).lock() {
                Ok(mut slot) => {
                    *slot = Some(state);
                    status
                }
                Err(_) => json!({"error": "Brave engine lock unavailable"}),
            }
        }
        Err(error) => json!({"error": error}),
    }
}

fn query(input: &str) -> Value {
    let parsed = serde_json::from_str::<Value>(input);
    match (STATE.get_or_init(|| Mutex::new(None)).lock(), parsed) {
        (Ok(state), Ok(input)) => state
            .as_ref()
            .map(|s| s.query(&input))
            .unwrap_or(json!({"ready": false})),
        _ => json!({"error": "invalid Brave query"}),
    }
}

fn c_string(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

unsafe fn text<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        ""
    } else {
        CStr::from_ptr(p).to_str().unwrap_or("")
    }
}

#[no_mangle]
pub unsafe extern "C" fn cupitor_adblock_initialize(
    directory: *const c_char,
    platform: *const c_char,
) -> *mut c_char {
    c_string(
        std::panic::catch_unwind(|| initialize(text(directory), text(platform)))
            .unwrap_or(json!({"error": "Brave initialization failed"})),
    )
}

#[no_mangle]
pub unsafe extern "C" fn cupitor_adblock_query(input: *const c_char) -> *mut c_char {
    c_string(
        std::panic::catch_unwind(|| query(text(input)))
            .unwrap_or(json!({"error": "Brave query failed"})),
    )
}

#[no_mangle]
pub unsafe extern "C" fn cupitor_adblock_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use jni::objects::{JClass, JString};
    use jni::sys::jstring;
    use jni::JNIEnv;

    #[no_mangle]
    pub extern "system" fn Java_org_satya_cupitor_BraveNative_initialize(
        mut env: JNIEnv,
        _: JClass,
        directory: JString,
        platform: JString,
    ) -> jstring {
        let directory: String = env
            .get_string(&directory)
            .map(Into::into)
            .unwrap_or_default();
        let platform: String = env
            .get_string(&platform)
            .map(Into::into)
            .unwrap_or_default();
        let value = std::panic::catch_unwind(|| super::initialize(&directory, &platform))
            .unwrap_or(json!({"error": "Brave initialization failed"}));
        env.new_string(value.to_string())
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "system" fn Java_org_satya_cupitor_BraveNative_query(
        mut env: JNIEnv,
        _: JClass,
        input: JString,
    ) -> jstring {
        let input: String = env.get_string(&input).map(Into::into).unwrap_or_default();
        let value = std::panic::catch_unwind(|| super::query(&input))
            .unwrap_or(json!({"error": "Brave query failed"}));
        env.new_string(value.to_string())
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn state(rules: &str, platform: &str) -> State {
        State::build(
            &json!({"schema":1,"engine_version":ENGINE_VERSION,"version":1,
            "lists":[{"text":rules}],"resources":[]})
            .to_string(),
            platform,
        )
        .unwrap()
    }
    #[test]
    fn network_exceptions_and_domain_boundaries() {
        let s = state(
            "||ads.example^\n@@||ads.example/needed.js$script",
            "android",
        );
        let request = |url| {
            s.query(
                &json!({"op":"network","url":url,"source":"https://site.example/","type":"script"}),
            )
        };
        assert_eq!(request("https://ads.example/ad.js")["blocked"], true);
        assert_eq!(request("https://ads.example/needed.js")["blocked"], false);
        assert_eq!(
            request("https://ads.example.evil.test/ad.js")["blocked"],
            false
        );
    }
    #[test]
    fn platform_conditions_and_cosmetic_exceptions() {
        let rules = "!#if env_mobile\n||mobile-ad.example^\n!#else\n||desktop-ad.example^\n!#endif\nexample.com##.advert\nallowed.example.com#@#.advert";
        let s = state(rules, "android");
        assert!(
            s.query(&json!({"op":"page","url":"https://example.com/"}))["selectors"]
                .to_string()
                .contains(".advert")
        );
        assert!(
            !s.query(&json!({"op":"page","url":"https://allowed.example.com/"}))["selectors"]
                .to_string()
                .contains(".advert")
        );
        assert!(preprocess(rules, "android").unwrap().contains("mobile-ad"));
        assert!(!preprocess(rules, "android").unwrap().contains("desktop-ad"));
        assert!(preprocess("!#endif", "android").is_err());
    }
    #[test]
    fn webkit_rules_are_produced_by_brave_converter() {
        let s = state("||ads.example^\n@@||ads.example/needed.js$script", "macos");
        assert!(s.webkit["rules"].as_array().unwrap().len() >= 2);
        assert!(s.webkit.to_string().contains("ignore-previous-rules"));
    }
    #[test]
    fn shipped_lists_and_scriptlets_work_on_both_platforms() {
        use base64::Engine as _;
        use std::io::Read;
        let encoded: String = include_str!("../../../assets/adblock/bundle.json.gz.b64")
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        let compressed = base64::prelude::BASE64_STANDARD.decode(encoded).unwrap();
        let mut contents = String::new();
        flate2::read::GzDecoder::new(compressed.as_slice())
            .read_to_string(&mut contents)
            .unwrap();
        for platform in ["android", "macos"] {
            let s = State::build(&contents, platform).unwrap();
            assert_eq!(
                s.query(
                    &json!({"op":"network","url":"https://ads.doubleclick.net/banner.js",
                "source":"https://example.com/","type":"script"})
                )["blocked"],
                true
            );
            let page = s.query(&json!({"op":"page","url":"https://www.youtube.com/watch?v=test"}));
            assert!(
                page["js"].as_str().unwrap().len() > 1000,
                "actual YouTube scriptlets must be available"
            );
            assert!(s.script.contains("jsonPrune") || s.script.contains("json-prune"));
            if platform == "android" {
                if let Ok(path) = std::env::var("CUPITOR_BRAVE_FIXTURE") {
                    std::fs::write(path, json!({"script":s.script,"page":page}).to_string())
                        .unwrap();
                }
            }
            if platform == "macos" {
                if let Ok(path) = std::env::var("CUPITOR_BRAVE_WEBKIT_FIXTURE") {
                    std::fs::write(path, s.webkit["rules"].to_string()).unwrap();
                }
                let count = s.webkit["rules"].as_array().unwrap().len();
                assert!(count > 1000);
                eprintln!("Brave converted {count} WebKit rules");
            }
        }
    }
    #[test]
    fn failed_update_retains_the_active_engine_through_the_c_abi() {
        let directory =
            std::env::temp_dir().join(format!("cupitor-brave-test-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let bundle = json!({"schema":1,"engine_version":ENGINE_VERSION,"version":7,
            "lists":[{"text":"||ads.example^"}],"resources":[]});
        std::fs::write(directory.join("bundle.json"), bundle.to_string()).unwrap();
        let path = CString::new(directory.to_str().unwrap()).unwrap();
        let platform = CString::new("android").unwrap();
        unsafe {
            let result = cupitor_adblock_initialize(path.as_ptr(), platform.as_ptr());
            assert!(text(result).contains("\"ready\":true"));
            cupitor_adblock_free(result);
            std::fs::write(directory.join("bundle.json"), "broken").unwrap();
            let result = cupitor_adblock_initialize(path.as_ptr(), platform.as_ptr());
            assert!(text(result).contains("error"));
            cupitor_adblock_free(result);
            let input = CString::new(r#"{"op":"status"}"#).unwrap();
            let result = cupitor_adblock_query(input.as_ptr());
            assert_eq!(
                serde_json::from_str::<Value>(text(result)).unwrap()["version"],
                7
            );
            cupitor_adblock_free(result);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
