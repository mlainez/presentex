defmodule Presentex.Pixel do
  @moduledoc """
  Renders a whole slide to an RGB pixel buffer: crisp truecolor text drawn with
  a `Presentex.Font`, and images composited at full resolution. This is what the
  framebuffer backend (and the PNG export) use, so a slide looks identical on a
  framebuffer/HDMI display and in a preview file — independent of the text
  console's color depth.
  """

  alias Presentex.{Renderer, Theme, Canvas, Image, Font, Parser.Slide}

  @doc """
  Render `slide` to `{rgb, width_px, height_px}`.

  Required opts: `:font`, `:width_px`, `:height_px`. Optional: `:scale` (font
  magnification, default 2), `:margin` (cells, default 3), `:reveal`,
  `:base_dir`, and footer fields `:index`, `:total`, `:title`.
  """
  @spec render(Slide.t(), map(), keyword()) :: {binary(), pos_integer(), pos_integer()}
  def render(%Slide{} = slide, theme, opts) do
    font = Keyword.fetch!(opts, :font)
    screen_w = Keyword.fetch!(opts, :width_px)
    screen_h = Keyword.fetch!(opts, :height_px)
    scale = Keyword.get(opts, :scale, 2)
    margin = Keyword.get(opts, :margin, 3)

    cell_w = font.width * scale
    cell_h = font.height * scale
    cols = div(screen_w, cell_w)
    rows = div(screen_h, cell_h)
    content_cols = max(cols - 2 * margin, 10)
    body_rows = max(rows - 1, 1)

    lines =
      Renderer.render(slide, theme, content_cols, Keyword.get(opts, :reveal, 9999),
        base_dir: Keyword.get(opts, :base_dir, "."),
        image_mode: :reserve,
        cell_px: {cell_w, cell_h},
        max_image_rows: body_rows - 1
      )

    top_pad =
      if slide.center?,
        do: max(div(body_rows - length(lines), 2), 0),
        else: 1

    {grid, overlays} = to_grid(lines, slide.center?, content_cols, font)

    origin_x = margin * cell_w
    origin_y = top_pad * cell_h

    canvas =
      Canvas.new(screen_w, screen_h, Theme.background())
      |> Canvas.draw_grid(grid, font, scale, origin_x, origin_y)
      |> draw_footer(opts, theme, font, scale, margin, cols, rows, cell_w, cell_h, content_cols)
      |> blit_overlays(overlays, font, scale, origin_x, origin_y, cell_w, cell_h)

    {Canvas.to_rgb(canvas), screen_w, screen_h}
  end

  # Substitutions for codepoints a font may lack, so typographic punctuation
  # doesn't render as blank gaps.
  @fallbacks %{
    0x2014 => ?-,
    0x2013 => ?-,
    0x2018 => ?',
    0x2019 => ?',
    0x201C => ?",
    0x201D => ?",
    0x2026 => ?.,
    0x00A0 => ?\s,
    # bullets -> middle dot (present in the built-in font)
    0x2022 => 0x00B7,
    0x25E6 => 0x00B7,
    0x2023 => ?>
  }

  # ── grid construction ───────────────────────────────────────────────────────
  defp to_grid(lines, center?, content_cols, font) do
    bg = Theme.background()
    blank = {32, bg, bg}

    {grid, overlays, _} =
      Enum.reduce(lines, {[], [], 0}, fn line, {grid, overlays, i} ->
        case line do
          [{:overlay, m}] ->
            row = List.duplicate(blank, content_cols)
            ov = %{line: i, col: m.col, cell_w: m.cell_w, cell_h: m.cell_h, path: m.path}
            {[row | grid], [ov | overlays], i + 1}

          runs ->
            row = line_to_cells(runs, center?, content_cols, blank, font)
            {[row | grid], overlays, i + 1}
        end
      end)

    {Enum.reverse(grid), Enum.reverse(overlays)}
  end

  defp line_to_cells(runs, center?, content_cols, blank, font) do
    cells = Enum.flat_map(runs, &run_to_cells(&1, font))
    pad = if center?, do: max(div(content_cols - length(cells), 2), 0), else: 0
    (List.duplicate(blank, pad) ++ cells) |> fit(content_cols, blank)
  end

  defp run_to_cells({text, style}, font) do
    fg = Theme.resolve_color(style[:fg], Theme.foreground())
    bg = Theme.resolve_color(style[:bg], Theme.background())
    for cp <- String.to_charlist(text), do: {glyph_cp(cp, font), fg, bg}
  end

  defp glyph_cp(cp, font) do
    if Font.has?(font, cp), do: cp, else: Map.get(@fallbacks, cp, cp)
  end

  defp fit(cells, width, blank) do
    case length(cells) do
      n when n == width -> cells
      n when n < width -> cells ++ List.duplicate(blank, width - n)
      _ -> Enum.take(cells, width)
    end
  end

  # ── footer ──────────────────────────────────────────────────────────────────
  defp draw_footer(
         canvas,
         opts,
         theme,
         font,
         scale,
         margin,
         _cols,
         rows,
         cell_w,
         cell_h,
         content_cols
       ) do
    total = Keyword.get(opts, :total, 1)
    num = Keyword.get(opts, :index, 0) + 1
    title = Keyword.get(opts, :title, "")

    right = "#{num} / #{total}"
    progress = progress_bar(num, total, min(content_cols, 24))

    gap =
      max(
        content_cols - String.length(title) - String.length(right) - String.length(progress) - 2,
        1
      )

    runs = [
      {title, Theme.role(theme, :footer)},
      {String.duplicate(" ", gap), %{}},
      {progress <> " ", Theme.role(theme, :footer_progress)},
      {right, Theme.role(theme, :footer)}
    ]

    bg = Theme.background()
    cells = runs |> Enum.flat_map(&run_to_cells(&1, font)) |> fit(content_cols, {32, bg, bg})
    Canvas.draw_grid(canvas, [cells], font, scale, margin * cell_w, (rows - 1) * cell_h)
  end

  defp progress_bar(num, total, width) when total > 0 do
    filled = round(num / total * width)
    String.duplicate("█", filled) <> String.duplicate("░", max(width - filled, 0))
  end

  defp progress_bar(_, _, _), do: ""

  # ── image overlays ──────────────────────────────────────────────────────────
  defp blit_overlays(canvas, overlays, _font, _scale, origin_x, origin_y, cell_w, cell_h) do
    Enum.reduce(overlays, canvas, fn ov, c ->
      box_w = ov.cell_w * cell_w
      box_h = ov.cell_h * cell_h
      px = origin_x + ov.col * cell_w
      py = origin_y + ov.line * cell_h

      case Image.to_rgb(ov.path, box_w, box_h) do
        {:ok, {iw, ih, rgb}} ->
          Canvas.blit_rgb(c, rgb, iw, ih, px + div(box_w - iw, 2), py + div(box_h - ih, 2))

        _ ->
          c
      end
    end)
  end
end
