# tokimo-lib

Unified native binary builds for the Tokimo desktop OS.

This repository packages native dependencies consumed by the main Tokimo repo through `deps.toml`: https://github.com/tokimo-lab/tokimo

## One-GLib invariant

FFmpeg and libvips must ship exactly one `libglib` / `libgobject` / `libgio` source. Mixing GLib providers is not supported.

## Non-goals

- No Rust code lives in this repository.
