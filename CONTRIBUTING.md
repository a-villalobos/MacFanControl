# Contributing

## Development workflow

1. Create a focused branch from `main`.
2. Make and commit one coherent change at a time.
3. Run `./scripts/check.sh`.
4. Run `./scripts/build.sh` for changes that affect the menu app, helper, packaging, or Rust binary.
5. Open a pull request into `main` and wait for the **Build and test** workflow to pass.
6. Merge the pull request and delete the branch.

Do not commit generated `target/`, `build/`, or `dist/` content. GitHub Actions produces a downloadable `Fan-macOS` artifact for every successful pull request and `main` build.

## Local prerequisites

- macOS with the Xcode Command Line Tools (`swiftc`, `plutil`)
- Rust stable with `cargo`, `rustfmt`, and `clippy`

The canonical commands live in `scripts/`; local and CI builds use the same entry points.
