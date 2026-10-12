# Inkline

System-wide, **on-device** predictive-text autocomplete for macOS.

As you type in any app, Inkline predicts the rest of your sentence and shows it
as gray "ghost text" at the caret. Press <kbd>Tab</kbd> to accept it word by
word, or just keep typing to ignore it. Inference runs locally through
[`llama.cpp`](https://github.com/ggml-org/llama.cpp). Nothing you type leaves
your machine, and there is no telemetry.

> **Status:** early, but usable day to day on macOS. A Windows version is
> planned.

## Features

- Inline ghost-text completions in any app that exposes its text through
  Accessibility
- Accept word by word (<kbd>Tab</kbd>) or all at once (<kbd>`</kbd>)
- Runs any local GGUF model through `llama-server`
- Menu-bar app with a settings window: global on/off, per-app toggles, and
  password fields skipped by default
- Built-in model management: list and switch models, or download a `.gguf`
  by URL

## Requirements

- macOS 13 or later, Apple Silicon or Intel (macOS 14+ for browser support,
  see [App support](#app-support))
- Xcode command-line tools (Swift 6+)
- Rust toolchain (`rustup` / `cargo`)
- `llama-server` from llama.cpp:

  ```bash
  brew install llama.cpp
  ```

  Inkline finds it through `$INKLINE_LLAMA_SERVER`, then `/opt/homebrew/bin`,
  then `/usr/local/bin`, then `PATH`.

- A GGUF model. Inkline is tuned for **base** (non-instruct) models; development
  uses `gemma-4-E2B.Q6_K.gguf`. Put it in `models/` or download one from inside
  the app.

## Getting started

```bash
git clone <repo-url> inkline && cd inkline

./scripts/setup-signing.sh   # once per machine: create a local signing cert
./run.sh                     # build, sign, and launch Inkline.app
```

`./run.sh --build` builds the app bundle (`mac/build/Inkline.app`) without
launching it.

The signing step keeps macOS from dropping the Accessibility permission each
time you rebuild. It creates a self-signed "Inkline Dev" identity and may ask
for your login password. If you skip it, the build falls back to ad-hoc
signing and you'll have to re-grant the permission after every build.

### Permissions

- **Accessibility** (required). macOS prompts on first launch. Grant it in
  System Settings → Privacy & Security → Accessibility. The menu-bar icon shows
  `✎⚠` until permission is granted, then `✎`.
- **Screen Recording** (optional). Used only to place ghost text in Chrome and
  Electron apps. macOS asks the first time you type in one of them.

### Try it

Open TextEdit, switch to plain text (Format → Make Plain Text), and start
typing. After a short pause, gray ghost text appears at the caret. The first
suggestion can take a few seconds while the model loads.

## Usage

While ghost text is visible:

| Key | Action |
| --- | --- |
| <kbd>Tab</kbd> | Accept the next word. Press again to keep going. |
| <kbd>`</kbd> | Accept the whole suggestion. |
| <kbd>Esc</kbd> | Dismiss. |
| any other key | Dismiss and keep typing. A new suggestion follows. |

While a suggestion is showing, <kbd>`</kbd> doesn't type a backtick. Press
<kbd>Esc</kbd> first if you need one.

### Settings

Open **✎ → Settings…** in the menu bar:

- **General:** turn Inkline on or off, skip password fields, and enable or
  disable it per app.
- **Models:** switch the active model, download a `.gguf` by URL, or change
  the models folder (default: `~/Library/Application Support/Inkline/models/`).

When you build from source, `run.sh` points the app at the first `*.gguf` in
the repo's `models/` folder. Choose a specific one with
`INKLINE_MODEL=models/your-model.gguf ./run.sh`.

## App support

Ghost text can only appear where Inkline can find the caret on screen, so
support depends on what each app exposes through Accessibility.

| App | Support |
| --- | --- |
| Native macOS apps (TextEdit, Notes, Mail, …) | ✅ |
| Safari | ✅ on most sites |
| Chrome / Electron apps | ✅ single-line fields, with Screen Recording on (macOS 14+) |
| Google Docs and other canvas-based editors | ❌ |

## How it works

Inkline has two parts:

- **`core/`**, a Rust library with a C interface. It handles debouncing,
  prompt building, cleaning up model output, and running `llama-server` as a
  child process that it talks to over localhost HTTP.
- **`mac/`**, a Swift menu-bar app that handles everything OS-specific:
  reading text and the caret position through Accessibility, intercepting
  keystrokes, drawing the ghost-text overlay, inserting accepted text, and
  storing settings.

The settings window is a single web page (`ui/settings.html`) hosted in a
WebView so a future Windows app can reuse it.

```text
inkline/
├── core/       Rust core (C interface generated with cbindgen)
├── mac/        Swift macOS app
├── ui/         shared settings / model-management UI
├── scripts/    setup-signing.sh
├── models/     local GGUF files (gitignored)
└── run.sh      build + launch
```

## Development

Run the core's unit tests:

```bash
cargo test -p inkline-core
```

View logs:

```bash
log stream --predicate 'process == "Inkline"' --level info

defaults write com.inkline.app InklineDebug -bool YES   # verbose caret/overlay logging
defaults delete com.inkline.app InklineDebug            # turn it off
```

`run.sh` launches the app with `open`, so environment variables don't reach it.
Use the `InklineDebug` setting above to turn on debug logging.

## Privacy

Inkline makes no network requests except to its own local `llama-server` and
to model URLs you choose to download. There's no telemetry or analytics.

## License

MIT
