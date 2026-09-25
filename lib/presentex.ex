defmodule Presentex do
  @moduledoc """
  A terminal Markdown presentation tool, in pure Elixir — a spiritual port of
  `presenterm` that runs anywhere the BEAM runs, including Nerves on exotic
  targets, with **no native dependencies and no cross-compilation**.

      Presentex.run("talk.md")
      Presentex.run("talk.md", theme: :default, margin: 4)
      Presentex.run("talk.md", terminal: MyDevice.Terminal)  # Nerves

  Navigation: -> / Space / Enter / n / j advance (and reveal `<!-- pause -->`
  steps); <- / p / k go back; g / Home jump to first; G / End to last; q quits.

  For non-interactive use (tests, snapshots, framebuffer rendering on hardware),
  `render_slide/3` returns the styled lines for one slide.
  """

  alias Presentex.{Parser, Presenter, Renderer, Theme}

  @doc "Parse and present a markdown file. Blocks until the user quits."
  @spec run(Path.t(), keyword()) :: :ok
  def run(path, opts \\ []) do
    opts = Keyword.put_new(opts, :base_dir, Path.dirname(path))

    path
    |> Parser.parse_file()
    |> Presenter.run(opts)
  end

  @doc "Present an already-loaded markdown string."
  @spec present_string(binary(), keyword()) :: :ok
  def present_string(source, opts \\ []) do
    source
    |> Parser.parse()
    |> Presenter.run(opts)
  end

  @doc """
  Render slide `index` (0-based) of `source` to a list of styled lines at the
  given `width`. Handy for tests or for blitting to a framebuffer instead of a
  terminal.
  """
  @spec render_slide(binary(), non_neg_integer(), keyword()) :: [[{binary(), map()}]]
  def render_slide(source, index, opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    theme = Theme.get(Keyword.get(opts, :theme, :default))
    deck = Parser.parse(source)

    render_opts =
      Keyword.take(opts, [:base_dir, :max_image_rows])
      |> Keyword.put_new(:base_dir, ".")

    case Enum.at(deck.slides, index) do
      nil -> []
      slide -> Renderer.render(slide, theme, width, 9999, render_opts)
    end
  end

  @doc "Parse a markdown string into a `%Presentex.Parser.Deck{}`."
  @spec parse(binary()) :: Parser.Deck.t()
  defdelegate parse(source), to: Parser

  @doc """
  Render slide `index` of a markdown file to a PNG (the same pixel pipeline the
  framebuffer backend uses). Lets you preview the beautiful renderer without
  hardware, or export a whole deck to images.

  Opts: `:font` (default the built-in 8x8), `:width_px` (1280), `:height_px`
  (720), `:scale` (3), `:margin`, `:theme`, `:reveal`.
  """
  @spec export_png(Path.t(), non_neg_integer(), Path.t(), keyword()) :: Path.t()
  def export_png(deck_path, index, out_path, opts \\ []) do
    deck = Parser.parse_file(deck_path)
    slide = Enum.at(deck.slides, index)
    theme = Theme.get(Keyword.get(opts, :theme, :default))
    font = Keyword.get(opts, :font, Presentex.Font.Builtin.font())

    pixel_opts =
      opts
      |> Keyword.put_new(:width_px, 1280)
      |> Keyword.put_new(:height_px, 720)
      |> Keyword.put_new(:scale, 3)
      |> Keyword.merge(
        font: font,
        index: index,
        total: length(deck.slides),
        title: Map.get(deck.meta, "title", ""),
        base_dir: Path.dirname(deck_path)
      )

    {rgb, w, h} = Presentex.Pixel.render(slide, theme, pixel_opts)
    File.write!(out_path, Presentex.Image.PNG.encode(w, h, rgb))
    out_path
  end
end
