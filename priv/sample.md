---
title: Presentations on the BEAM
author: Marc
---

<!-- center -->

# Presentex

Presenting from the BEAM, no native deps.

A pure-Elixir port of *presenterm*.

<!-- end_slide -->

# Why pure Elixir?

The Rust original needs **Oniguruma** — a C regex library pulled in by `syntect`.

- Native C deps mean a build toolchain for every target you ship to
- Cross-compiling that C dep for embedded/big-endian targets is painful
- Pure Elixir compiles to **portable BEAM bytecode** — no target build at all

> If it runs the BEAM, it runs this — desktop, server, or an embedded board.

<!-- end_slide -->

# Syntax highlighting, no C

The highlighter is a small hand-written tokenizer:

```elixir
def highlight(code, lang, theme) do
  code
  |> String.split("\n")           # comment survives
  |> Enum.map(&highlight_line(&1, lang, theme))
end
```

<!-- pause -->

It is approximate, but needs **zero NIFs**.

<!-- pause -->

Swap in `makeup` later for full grammars — same seam.

<!-- end_slide -->

# Comparison

| Approach        | Native deps | Cross-compile |
|-----------------|-------------|---------------|
| presenterm (Rust) | Oniguruma | required      |
| Presentex (Elixir)| none      | none          |

<!-- end_slide -->

# A picture, no protocol needed

![gradient](grad.png)

Rendered as truecolor half-blocks — works over serial too.

<!-- end_slide -->

<!-- center -->

# Questions?

Find the code at [the repo](https://github.com/mlainez/presentex).
