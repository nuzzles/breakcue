# Contributing to BreakCue

Thanks for considering a contribution. Issues and pull requests are welcome.

## Getting started

BreakCue requires macOS 13 or later, Rust, and the Apple command line tools. Clone the repository and build the app and DMG:

```sh
git clone https://github.com/nuzzles/breakcue.git
cd breakcue
./package.sh
```

The reminder engine is in `src/main.rs`; the native menu bar interface is in `macos/app.m`. Default settings live in `settings.toml`.

## Before opening a PR

Run the same checks as CI:

```sh
cargo fmt -- --check
cargo check --locked
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

Run `cargo fmt` to apply formatting changes. If you change packaging or the menu bar interface, run `./package.sh` and check the resulting app on macOS.

## Filing issues

For bugs, include your macOS version, BreakCue version or commit, steps to reproduce, and the expected and actual behavior. Screenshots are useful for visual issues. For feature requests, describe the use case.

## Branches and review

Branch from `main` and keep commits focused. Open a pull request against `main`; CI must pass before merge. A maintainer may ask for changes during review.

Unless you explicitly state otherwise, contributions intentionally submitted for inclusion in BreakCue are licensed under both Apache-2.0 and MIT, as described in the [README](README.md#license).
