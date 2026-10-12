use std::path::PathBuf;

// Generate the C header (include/inkline.h) from the Rust source on every build,
// so the native shells always link against an up-to-date FFI surface.
fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let out_path = PathBuf::from(&crate_dir).join("include").join("inkline.h");

    std::fs::create_dir_all(out_path.parent().unwrap())
        .expect("failed to create include/ directory");

    match cbindgen::generate(&crate_dir) {
        Ok(bindings) => {
            bindings.write_to_file(&out_path);
        }
        Err(err) => {
            // Don't hard-fail the build if header generation hiccups; surface it loudly.
            eprintln!("cbindgen: failed to generate header: {err}");
        }
    }

    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=src/stub.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
}
