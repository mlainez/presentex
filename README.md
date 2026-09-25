# Presentex

A terminal **and framebuffer** Markdown presentation tool in **pure Elixir** — a
spiritual port of [presenterm](https://github.com/mfontanini/presenterm) that
runs anywhere the BEAM runs, from a laptop to an embedded board, with no native
dependencies and no cross-compilation.

## Why this exists

presenterm is Rust; its highlighting pulls in `syntect` → **Oniguruma** (a C
regex library), and cross-compiling that C dep for every target you ship to is
the painful part — especially embedded or big-endian boards. Elixir compiles to
architecture-independent **BEAM bytecode**, so a pure-Elixir presenter needs no
target build step. Even the parts you'd expect to need native code don't:

- **Syntax highlighting** — a hand-written tokenizer, no regex engine.
- **PNG decoding/encoding** — uses ERTS's built-in `:zlib`.
- **Images on a console** — truecolor half-blocks, no terminal image protocol.
- **Beautiful HDMI output** — a bitmap-font pixel renderer that draws crisp
  truecolor text and full-resolution images straight to the framebuffer.
- **Controller / clicker input** — any evdev device is read with a small
  endian-aware parser, so it works on little- and big-endian targets alike.

## Quick start

```bash
mix escript.build              # zero hex deps to fetch
./presentex priv/sample.md     # interactive, in your terminal
./presentex --export out/ priv/sample.md   # render slides to PNGs (no hardware)
```

```elixir
Presentex.run("priv/sample.md")
Presentex.export_png("priv/sample.md", 0, "title.png", scale: 3)
```

### Keys

| Keyboard                | Controller      | Action                      |
|-------------------------|-----------------|-----------------------------|
| `->` `Space` `Enter` `n`| A / `+` / D-pad→| next (reveals `pause` steps)|
| `<-` `p` `k`            | B / `-` / D-pad←| previous                    |
| `g` / `Home`            | D-pad↑          | first slide                 |
| `G` / `End`             | D-pad↓          | last slide                  |
| `q`                     | Home button     | quit                        |

## Three ways to display

### 1. Console, truecolor (default)

Text and tables render as ANSI; images become **half-blocks** (`▀`, top pixel =
foreground, bottom = background — two vertical pixels per cell). Needs only
truecolor ANSI, so it works on any modern terminal and **over a serial console**.

### 2. Framebuffer pixels — the beautiful HDMI path

```bash
./presentex --framebuffer --scale 2 priv/sample.md
./presentex --framebuffer --evdev --device /dev/input/event0 priv/sample.md
```

```elixir
Presentex.run("talk.md",
  terminal: Presentex.Terminal.Framebuffer,
  terminal_opts: [
    device: "/dev/fb0", width_px: 1280, height_px: 720,
    bytes_per_line: 1280 * 4,   # fb_fix_screeninfo.line_length; defaults to width*bpp
    format: :xrgb8888,          # or :rgb565
    scale: 2,                   # font magnification
    input: :evdev, input_device: "/dev/input/event0", layout: :le64
  ])
```

This bypasses the text console entirely: it rasterizes each slide to an RGB
buffer — crisp truecolor text from a bitmap font, images blitted at **full
resolution** — packs it to the framebuffer's pixel format, and writes the whole
frame in one `pwrite`. So the slide looks the same whether the console is
16-color or not. Read your geometry with `fbset` or `/sys/class/graphics/fb0/`.

### 3. PNG export

`--export DIR` (or `Presentex.export_png/4`) renders slides through the exact
same pixel pipeline to PNG files — for previewing the framebuffer look without
hardware, or exporting a deck to images.

## Fonts

The framebuffer renderer ships with an embedded **8x8 font** (public-domain
font8x8) covering Latin, box-drawing, and block glyphs — zero config. `--scale`
magnifies it (2 → 16px cells ≈ 80×45 on 720p; 3 → bigger text, fewer columns).

For a crisp high-resolution look on a projector, drop in a **PSF font** (e.g.
Spleen or Terminus, which ship as PSF2) and the renderer will use it at native
resolution; its embedded unicode table is parsed so box-drawing maps correctly:

```bash
./presentex --framebuffer --font priv/fonts/spleen-16x32.psfu priv/sample.md
```

```elixir
{:ok, font} = Presentex.Font.PSF.load("priv/fonts/spleen-16x32.psfu")
```

Glyphs a font lacks (em dash, curly quotes, bullets) fall back to sensible ASCII.

## evdev input devices

Any input device — a presenter clicker, gamepad, or keyboard — shows up under
`/dev/input/event*`, so its D-pad and buttons arrive as ordinary Linux input
events. A `struct input_event` is a `timeval` then `__u16 type, __u16 code,
__s32 value`; the timeval size varies, but `type/code/value` are always the
**last 8 bytes**, so the reader only needs the record size and byte order. Pick
the matching layout:

| Layout  | Record size | Byte order    | Typical target              |
|---------|-------------|---------------|-----------------------------|
| `:le64` | 24 bytes    | little-endian | 64-bit hosts (the default)  |
| `:le32` | 16 bytes    | little-endian | 32-bit hosts                |
| `:be64` | 24 bytes    | big-endian    | 64-bit big-endian targets   |
| `:be32` | 16 bytes    | big-endian    | 32-bit big-endian (PowerPC) |

If events look wrong, confirm the record size with `evtest` (try 16 vs 24) and
override the button-code map if the driver assigns different codes:

```elixir
terminal_opts: [..., layout: :le64,
                buttons: %{0x130 => :space, 0x131 => :backspace, 0x13C => :quit}]
```

> **Big-endian / embedded targets.** Because the parser is endian-aware and the
> whole tool is portable BEAM bytecode, it also runs on big-endian boards with
> no native build step — e.g. the 32-bit PowerPC Nintendo Wii U under Nerves,
> whose GamePad is a standard evdev device: use `layout: :be32`.

## Architecture

```
Presentex              public API (run / render_slide / export_png / parse)
Presentex.Parser       markdown -> %Deck{slides: [%Slide{blocks}]}
Presentex.Renderer     blocks -> wrapped lines of {text, style} runs
Presentex.Highlighter  code -> styled runs (hand-written tokenizer)
Presentex.Style        run -> ANSI (named + 24-bit color); width-aware wrap
Presentex.Theme        semantic role -> style; named-color -> RGB palette
Presentex.Image        PNG -> half-blocks (console) or scaled RGB (pixels)
Presentex.Image.PNG    pure-Elixir PNG decoder + encoder (:zlib)
Presentex.Font         bitmap font struct + pixel lookup
  .Builtin             embedded public-domain 8x8 font
  .PSF                 PSF1/PSF2 loader (with unicode table)
Presentex.Canvas       RGB pixel buffer: rasterize text grid, blit images
Presentex.Pixel        lay out a slide -> pixels (text + full-res images)
Presentex.Framebuffer  pack/blit RGB to /dev/fb0 (xrgb8888 / rgb565)
Presentex.Frame        the slide model handed to a backend each draw
Presentex.Terminal     behaviour: setup / teardown / read_key / draw(frame)
  .Console             shared ANSI: screen control, frame composition, stdin
  .Default             ANSI console + raw stdin
  .Evdev               ANSI console + evdev input device
  .Framebuffer         pixel output to /dev/fb0 + stdin or evdev input
Presentex.Input.Evdev  endian-aware event decode + button mapping
Presentex.Presenter    the run loop / navigation state machine
```

The loop hands each backend a `%Frame{}` (a slide model), not pre-baked bytes, so
the same navigation drives ANSI text and framebuffer pixels alike — each backend
composes its own output while sharing the parser, renderer, and highlighter.

## Tests

```bash
mix test
```

Covers parsing and every block type, pause gating, width-bounded wrapping, the
PNG decoder (against a known image), half-block rendering, the bitmap font and
canvas rasterization, PSF parsing, the full pixel slide renderer, framebuffer
packing/striding, endian-aware evdev decode/mapping and the input reader, and a
full presenter loop driven by a fake terminal.
