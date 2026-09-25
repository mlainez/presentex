defmodule Presentex.Theme do
  @moduledoc """
  Color/style themes. A theme maps semantic roles (heading, code, accent, …)
  to a `style` map: `%{fg: color, bold: bool, italic: bool, faint: bool,
  underline: bool, reverse: bool}`.

  Colors are atoms understood by `Presentex.Style`, e.g. `:cyan`,
  `:light_blue`, `:bright_white`. Keeping styles abstract (rather than raw
  escape codes) means rendering and width calculations stay separate from the
  bytes we eventually emit — handy when a Nerves target has a quirky terminal.
  """

  @type color :: atom()
  @type style :: %{optional(atom()) => boolean() | color()}

  @default %{
    title: %{fg: :bright_white, bold: true},
    heading1: %{fg: :light_cyan, bold: true},
    heading2: %{fg: :light_blue, bold: true},
    heading3: %{fg: :cyan, bold: true},
    heading4: %{fg: :cyan, italic: true},
    text: %{},
    strong: %{bold: true, fg: :bright_white},
    em: %{italic: true},
    inline_code: %{fg: :light_green},
    code_default: %{fg: :light_green, faint: true},
    bullet: %{fg: :light_magenta, bold: true},
    enum: %{fg: :light_magenta, bold: true},
    quote_bar: %{fg: :light_black},
    quote_text: %{fg: :white, italic: true},
    link: %{fg: :light_blue, underline: true},
    link_url: %{fg: :light_black, faint: true},
    rule: %{fg: :light_black},
    image: %{fg: :light_yellow},
    table_head: %{fg: :light_cyan, bold: true},
    table_border: %{fg: :light_black},
    footer: %{fg: :light_black},
    footer_progress: %{fg: :light_magenta},
    # syntax-highlight token roles
    syn_keyword: %{fg: :light_magenta},
    syn_string: %{fg: :light_green},
    syn_number: %{fg: :light_yellow},
    syn_comment: %{fg: :light_black, italic: true},
    syn_func: %{fg: :light_blue},
    syn_punct: %{fg: :white}
  }

  @doc "Return the named theme as a role => style map. Currently `:default`."
  @spec get(atom()) :: %{atom() => style()}
  def get(:default), do: @default
  def get(_other), do: @default

  @doc "Look up a single role, falling back to an empty (plain) style."
  @spec role(%{atom() => style()}, atom()) :: style()
  def role(theme, name), do: Map.get(theme, name, %{})

  @palette %{
    black: {30, 30, 38},
    red: {200, 70, 70},
    green: {120, 190, 110},
    yellow: {210, 180, 90},
    blue: {90, 130, 210},
    magenta: {180, 110, 200},
    cyan: {90, 180, 195},
    white: {200, 205, 215},
    light_black: {110, 115, 130},
    light_red: {235, 110, 110},
    light_green: {150, 220, 130},
    light_yellow: {240, 215, 120},
    light_blue: {120, 165, 240},
    light_magenta: {210, 140, 235},
    light_cyan: {120, 215, 230},
    bright_white: {245, 247, 252}
  }

  @bg {18, 20, 28}
  @fg {210, 214, 224}

  @doc "Default background / foreground RGB for pixel rendering."
  def background, do: @bg
  def foreground, do: @fg

  @doc "Resolve a style's color value (named atom, `{r,g,b}`, or nil) to RGB."
  @spec resolve_color(term(), {0..255, 0..255, 0..255}) :: {0..255, 0..255, 0..255}
  def resolve_color(nil, default), do: default
  def resolve_color({r, g, b}, _default), do: {r, g, b}
  def resolve_color(name, default) when is_atom(name), do: Map.get(@palette, name, default)
end
