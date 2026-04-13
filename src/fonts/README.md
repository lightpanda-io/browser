# Font Files

This directory holds TTF font files used by Lightpanda for text shaping and layout.

## Required Fonts

- **Liberation Sans** (Regular, Bold, Italic, BoldItalic) — metric-compatible with Arial
- **Liberation Serif** (Regular, Bold, Italic, BoldItalic) — metric-compatible with Times New Roman
- **Liberation Mono** (Regular, Bold, Italic, BoldItalic) — metric-compatible with Courier New
- **Ahem.ttf** — Web Platform Tests reference font (all glyphs are square blocks)

## Setup

Run the download script:

```console
./src/fonts/download_fonts.sh
```

On Linux, system fonts via fontconfig are also available. On macOS, CoreText provides system font discovery.
