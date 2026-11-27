//! The router's orb is the app's Metal shader carried over to GLSL. This keeps the two from drifting:
//! every function of FluidOrb.metal must exist in orb.frag under the same name.

use std::path::Path;

fn read(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn orb_shader_keeps_every_function_of_the_metal_one() {
    let metal = read("../../../ios/Listen/Views/FluidOrb.metal");
    let glsl = read("ui/orb.frag");
    let names = metal_functions(&metal);
    assert!(names.len() >= 7, "found {names:?} in the Metal shader");
    // Functions defined in the GLSL: an unindented line `<type> <name>(`.
    let defined: Vec<String> = glsl
        .lines()
        .filter(|line| !line.starts_with(' ') && !line.starts_with("//") && line.contains('('))
        .filter_map(|line| line.split('(').next())
        .filter_map(|head| {
            let words: Vec<&str> = head.split_whitespace().collect();
            (words.len() == 2).then(|| words[1].to_string())
        })
        .collect();
    for name in &names {
        assert!(defined.contains(name), "orb.frag defines no {name}(); it defines {defined:?}");
    }
    for uniform in ["u_gather", "u_lean", "u_since", "u_active", "u_dark", "u_bleed"] {
        assert!(glsl.contains(uniform), "orb.frag has no {uniform}");
    }
    assert!(glsl.contains("struct WingSample"));
}

/// The `static` functions of the Metal shader that the GLSL must have too. A `static constant`
/// is no function, and `forSRGBLayer` only undoes the encoding of the app's native sRGB layer,
/// which a WebGL canvas does not have.
fn metal_functions(metal: &str) -> Vec<String> {
    metal
        .lines()
        .filter_map(|line| line.trim().strip_prefix("static "))
        .filter(|rest| rest.contains('(') && !rest.starts_with("constant "))
        .filter_map(|rest| rest.split('(').next())
        .filter_map(|head| head.split_whitespace().last())
        .filter(|name| *name != "forSRGBLayer")
        .map(str::to_string)
        .collect()
}

#[test]
fn metal_constants_and_the_srgb_helper_are_not_asked_of_the_glsl() {
    let metal = "static constant int dayLook = 1;\nstatic float hash(float2 p) {\n\
                 static half4 forSRGBLayer(half4 c, float dark) {\n    static WingSample wingAt(float2 p,\n";
    assert_eq!(metal_functions(metal), ["hash", "wingAt"]);
}

#[test]
fn orb_has_the_day_look_of_the_app() {
    // On a light background the body glows white inside a cool bloom (docs/ARCHITECTURE.md, "Orb day look").
    let glsl = read("ui/orb.frag");
    assert!(glsl.contains("const int dayLook = 1;"));
    assert!(glsl.contains("if (dayLook != 0 && dark < 0.5)"));
}

#[test]
fn window_loads_nothing_from_outside() {
    for file in ["ui/index.html", "ui/app.js", "ui/orb.js", "ui/settings.js", "ui/style.css"] {
        let text = read(file);
        for bad in ["src=\"http", "href=\"http", "url(http", "@import", "fetch(\"http"] {
            assert!(!text.contains(bad), "{file} loads from outside: {bad}");
        }
    }
    let conf = read("tauri.conf.json");
    assert!(conf.contains("default-src 'self'"), "the CSP keeps everything inside the app");
}

#[test]
fn csp_lets_the_orb_load_its_own_shader() {
    // orb.js fetches ui/orb.frag; without 'self' in connect-src the app shows only the grey stand-in disc.
    assert!(read("ui/orb.js").contains("fetch(\"orb.frag\")"));
    let conf = read("tauri.conf.json");
    let connect = conf.split("connect-src").nth(1).expect("the CSP names connect-src");
    let connect = connect.split([';', '"']).next().unwrap();
    assert!(connect.contains("'self'"), "connect-src is \"{connect}\"");
}

#[test]
fn settings_tab_sets_text_not_html() {
    // Topic ids, folders and warnings may come from outside the window; they are set as text.
    assert!(!read("ui/settings.js").contains("innerHTML"));
}
