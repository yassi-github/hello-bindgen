extern crate bindgen;

use std::env;
use std::fs::File;
use std::io::{self, BufRead};
use std::path::PathBuf;

use bindgen::CargoCallbacks;

fn included_libname_quoted(line: String) -> Result<String, ()> {
    if !line.starts_with("#include") {
        return Err(());
    }
    let line_vec = line.split(' ').collect::<Vec<&str>>();
    // len will be longer than 3 if commented.
    if line_vec.len() >= 2 {
        // Tell ld to link with specified name by special comment.
        // Because system shared lib name is not always same with header name.
        // For example, bzip2 uses bzlib.h but lib name is `libbz2.so`,
        // so to avoid lookup `libbzlib.so` specify lib name "bz2".
        const LD_SPECIAL_SIGN: &str = "ld:-l";
        for word in &line_vec {
            if word.contains(LD_SPECIAL_SIGN) {
                let ldname = word.trim_start_matches(LD_SPECIAL_SIGN).to_string();
                if ldname.is_empty() {
                    return Err(());
                }
                // quote as system lib
                return Ok(format!("<{ldname}>"));
            }
        }
        // simple quoted header file name.
        return Ok(line_vec[1].to_string());
    }
    Err(())
}

fn build_c_libs(libname: String, libdir_path: PathBuf) {
    // This is the path to the intermediate object file for our library.
    let obj_path = libdir_path.join(format!("{libname}.o"));
    // This is the path to the static library file.
    let lib_path = libdir_path.join(format!("lib{libname}.a"));

    // // Tell cargo to tell rustc to link our `{libname}` library. Cargo will
    // // automatically know it must look for a `lib{libname}.a` file.
    println!("cargo:rustc-link-lib={libname}");

    // Run `clang` to compile the `{libname}.c` file into a `{libname}.o` object file.
    // Unwrap if it is not possible to spawn the process.
    if !std::process::Command::new("clang")
        .arg("-c")
        .arg("-o")
        .arg(&obj_path)
        .arg(libdir_path.join(format!("lib/{libname}.c")))
        .output()
        .expect("could not spawn `clang`")
        .status
        .success()
    {
        // Panic if the command was not successful.
        panic!("could not compile object file");
    }

    // Run `ar` to generate the `lib{libname}.a` file from the `{libname}.o` file.
    // Unwrap if it is not possible to spawn the process.
    if !std::process::Command::new("ar")
        .arg("rcs")
        .arg(lib_path)
        .arg(obj_path)
        .output()
        .expect("could not spawn `ar`")
        .status
        .success()
    {
        // Panic if the command was not successful.
        panic!("could not emit library file");
    }
}

fn main() {
    // This is the directory where the `c` library is located.
    let libdir_path = PathBuf::from("bindgen")
        // Canonicalize the path as `rustc-link-search` requires an absolute path.
        .canonicalize()
        .expect("cannot canonicalize path");

    // Tell cargo to look for shared libraries in the specified directory
    println!("cargo:rustc-link-search={}", libdir_path.to_str().unwrap());

    // This is the path to the `c` headers wrapper file.
    let headers_path = libdir_path.join("bindgen_helper.h");
    let headers_path_str = headers_path.to_str().expect("Path is not a valid string");

    let file = File::open(headers_path_str).expect("Failed to open bindgen headers file");
    let reader = io::BufReader::new(file);
    for line in reader.lines() {
        match line {
            Ok(linetext) => {
                if let Ok(libname_quoted) = included_libname_quoted(linetext) {
                    if libname_quoted.starts_with('<') {
                        // system lib is quoted with "<>"
                        let libbasename = libname_quoted
                            .trim_matches(|c| c == '<' || c == '>')
                            .trim_end_matches(".h");
                        println!("cargo:rustc-link-lib={libbasename}"); // ld.lld: error: unable to find library -lbzlib
                    }
                    if libname_quoted.starts_with('"') {
                        // user lib is quoted with '""'
                        let libname_unquoted = libname_quoted.trim_matches('"');
                        let libbasename_vec = libname_unquoted.split('/').collect::<Vec<&str>>();
                        let libbasename = libbasename_vec[libbasename_vec.len() - 1]
                            .trim_end_matches(".h")
                            .to_string();
                        build_c_libs(libbasename, libdir_path.clone());
                    }
                }
            }
            Err(e) => {
                panic!("Error reading line: {}", e);
            }
        }
    }

    // Tell cargo to invalidate the built crate whenever the header changes.
    println!("cargo:rerun-if-changed={headers_path_str}");

    // The bindgen::Builder is the main entry point
    // to bindgen, and lets you build up options for
    // the resulting bindings.
    let bindings = bindgen::Builder::default()
        // The input header we would like to generate
        // bindings for.
        .header(headers_path_str)
        // Tell cargo to invalidate the built crate whenever any of the
        // included header files changed.
        .parse_callbacks(Box::new(CargoCallbacks))
        // Finish the builder and generate the bindings.
        .generate()
        // Unwrap the Result and panic on failure.
        .expect("Unable to generate bindings");

    // Write the bindings to the $OUT_DIR/bindings.rs file.
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap()).join("bindings.rs");
    bindings
        .write_to_file(out_path)
        .expect("Couldn't write bindings!");
}
