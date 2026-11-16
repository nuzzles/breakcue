fn main() {
    println!("cargo:rerun-if-changed=macos/app.m");
    cc::Build::new()
        .file("macos/app.m")
        .flag("-fobjc-arc")
        .compile("breakcue_appkit");
    for framework in ["AppKit", "CoreGraphics", "IOKit", "ServiceManagement"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
