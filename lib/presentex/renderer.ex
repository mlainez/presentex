defmodule Presentex.Renderer do
  @moduledoc """
  Turns a parsed slide's blocks into a list of *lines*, where each line is a
  list of `{text, style}` runs already wrapped to `width`. The presenter is
  responsible for margins, vertical placement and the footer.
  """

  alias Presentex.{Style, Theme, Highlighter}
  alias Presentex.Parser.Slide

  @doc """
  Render a slide to lines of runs. `reveal_step` controls how many `pause`
  segments are shown (0 = up to the first pause).
  """
  @spec render(Slide.t(), map(), pos_integer(), non_neg_integer(), keyword()) ::
          [[{binary(), map()}]]
  def render(%Slide{blocks: blocks}, theme, width, reveal_step \\ 9999, opts \\ []) do
    blocks
    |> visible_blocks(reveal_step)
    |> Enum.map(fn
      {:image, alt, path} -> render_image(alt, path, theme, width, opts)
      block -> render_block(block, theme, width)
    end)
    |> Enum.intersperse([[{"", %{}}]])
    |> Enum.concat()
  end

  # Keep blocks up to and including the (reveal_step)-th pause group.
  defp visible_blocks(blocks, reveal_step) do
    blocks
    |> Enum.reduce({0, []}, fn
      :pause, {seen, acc} -> {seen + 1, acc}
      block, {seen, acc} when seen <= reveal_step -> {seen, [block | acc]}
      _block, acc -> acc
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # ── individual blocks ───────────────────────────────────────────────────────
  defp render_block({:heading, level, inline}, theme, width) do
    role = heading_role(level)
    base = Theme.role(theme, role)
    runs = inline_to_runs(inline, theme, base)
    lines = Style.wrap(runs, width)

    case level do
      n when n in [1, 2] ->
        underline_char = if n == 1, do: "═", else: "─"
        w = lines |> Enum.map(&Style.visible_width/1) |> Enum.max(fn -> 0 end)
        lines ++ [[{String.duplicate(underline_char, w), Theme.role(theme, :rule)}]]

      _ ->
        lines
    end
  end

  defp render_block({:paragraph, inline}, theme, width) do
    inline
    |> inline_to_runs(theme, Theme.role(theme, :text))
    |> Style.wrap(width)
  end

  defp render_block({:code, lang, code}, theme, width) do
    bar = {"▏ ", Theme.role(theme, :rule)}
    inner_w = max(width - 2, 1)

    code
    |> Highlighter.highlight(lang, theme)
    |> Enum.map(fn run_line -> [bar | truncate_runs(run_line, inner_w)] end)
  end

  defp render_block({:quote, lines}, theme, width) do
    bar = {"│ ", Theme.role(theme, :quote_bar)}
    base = Theme.role(theme, :quote_text)
    inner_w = max(width - 2, 1)

    Enum.flat_map(lines, fn line ->
      runs = line |> Presentex.Parser.parse_inline() |> inline_to_runs(theme, base)

      case Style.wrap(runs, inner_w) do
        [] -> [[bar]]
        wrapped -> Enum.map(wrapped, fn l -> [bar | l] end)
      end
    end)
  end

  defp render_block({:list, kind, items}, theme, width) do
    Enum.flat_map(items, fn {lvl, inline} ->
      indent = String.duplicate("  ", lvl)
      marker = list_marker(kind, lvl, theme)
      hang = String.duplicate(" ", String.length(indent) + visible_len(marker))
      avail = max(width - String.length(indent) - visible_len(marker), 1)

      runs = inline_to_runs(inline, theme, Theme.role(theme, :text))

      case Style.wrap(runs, avail) do
        [] ->
          [[{indent, %{}}, marker]]

        [first | rest] ->
          [[{indent, %{}}, marker | first]] ++
            Enum.map(rest, fn l -> [{hang, %{}} | l] end)
      end
    end)
  end

  defp render_block(:hr, theme, width) do
    [[{String.duplicate("─", width), Theme.role(theme, :rule)}]]
  end

  defp render_block({:table, headers, rows}, theme, width) do
    render_table(headers, rows, theme, width)
  end

  # ── inline → runs ───────────────────────────────────────────────────────────
  defp render_image(alt, path, theme, width, opts) do
    base_dir = Keyword.get(opts, :base_dir, ".")
    resolved = if Path.type(path) == :absolute, do: path, else: Path.join(base_dir, path)

    case Keyword.get(opts, :image_mode, :halfblock) do
      :halfblock ->
        max_rows = Keyword.get(opts, :max_image_rows, 16)

        case Presentex.Image.render(resolved, width, max_rows) do
          {:ok, lines} -> lines
          {:error, _reason} -> [image_placeholder(alt, path, theme)]
        end

      :reserve ->
        reserve_image(resolved, alt, path, theme, width, opts)
    end
  end

  # For the pixel/framebuffer renderer: reserve a block of blank cells and emit
  # an overlay marker on the first line; the image is blitted at full resolution.
  defp reserve_image(resolved, alt, path, theme, width, opts) do
    {cw, ch} = Keyword.get(opts, :cell_px, {8, 16})
    max_rows = Keyword.get(opts, :max_image_rows, 16)

    case Presentex.Image.dimensions(resolved) do
      {:ok, {iw, ih}} ->
        scale = min(width * cw / iw, max_rows * ch / ih) |> min(1.0)
        out_pw = max(round(iw * scale), 1)
        out_ph = max(round(ih * scale), 1)
        cell_w = out_pw |> ceil_div(cw) |> clamp(1, width)
        cell_h = out_ph |> ceil_div(ch) |> clamp(1, max_rows)
        col = div(width - cell_w, 2)

        overlay = {:overlay, %{path: resolved, cell_w: cell_w, cell_h: cell_h, col: col}}
        [[overlay] | List.duplicate([{"", %{}}], cell_h - 1)]

      {:error, _} ->
        [[image_placeholder(alt, path, theme)]]
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp image_placeholder(alt, path, theme) do
    label = if alt == "", do: path, else: "#{alt} — #{path}"
    [{"🖼  [image: #{label}]", Theme.role(theme, :image)}]
  end

  defp inline_to_runs(inline, theme, base) do
    Enum.flat_map(inline, fn
      {:text, t} ->
        [{t, base}]

      {:strong, inner} ->
        inline_to_runs(inner, theme, Map.merge(base, Theme.role(theme, :strong)))

      {:em, inner} ->
        inline_to_runs(inner, theme, Map.merge(base, Theme.role(theme, :em)))

      {:code, t} ->
        [{t, Map.merge(base, Theme.role(theme, :inline_code))}]

      {:link, label, url} ->
        link = [{label, Map.merge(base, Theme.role(theme, :link))}]

        if String.trim(label) == String.trim(url) do
          link
        else
          link ++ [{" (#{url})", Map.merge(base, Theme.role(theme, :link_url))}]
        end
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────
  defp heading_role(1), do: :heading1
  defp heading_role(2), do: :heading2
  defp heading_role(3), do: :heading3
  defp heading_role(_), do: :heading4

  defp list_marker(:ul, lvl, theme) do
    glyph = Enum.at(["•", "◦", "‣"], rem(lvl, 3))
    {glyph <> " ", Theme.role(theme, :bullet)}
  end

  defp list_marker(:ol, _lvl, theme), do: {"• ", Theme.role(theme, :enum)}

  defp visible_len({text, _}), do: String.length(text)

  defp truncate_runs(runs, max_w) do
    {kept, _} =
      Enum.reduce(runs, {[], 0}, fn {t, s}, {acc, used} ->
        remaining = max_w - used

        cond do
          remaining <= 0 -> {acc, used}
          String.length(t) <= remaining -> {[{t, s} | acc], used + String.length(t)}
          true -> {[{String.slice(t, 0, remaining), s} | acc], max_w}
        end
      end)

    Enum.reverse(kept)
  end

  defp render_table(headers, rows, theme, width) do
    cols = length(headers)
    all = [headers | rows]

    widths =
      for c <- 0..(cols - 1) do
        all
        |> Enum.map(fn row ->
          row |> Enum.at(c, []) |> inline_to_runs(theme, %{}) |> Style.visible_width()
        end)
        |> Enum.max(fn -> 0 end)
      end

    widths = fit_widths(widths, width, cols)
    border = Theme.role(theme, :table_border)

    sep = [{"├" <> Enum.map_join(widths, "┼", &String.duplicate("─", &1 + 2)) <> "┤", border}]

    top = [{"┌" <> Enum.map_join(widths, "┬", &String.duplicate("─", &1 + 2)) <> "┐", border}]

    bottom = [{"└" <> Enum.map_join(widths, "┴", &String.duplicate("─", &1 + 2)) <> "┘", border}]

    head_line = row_line(headers, widths, theme, border, Theme.role(theme, :table_head))
    body_lines = Enum.map(rows, &row_line(&1, widths, theme, border, Theme.role(theme, :text)))

    [top, head_line, sep] ++ body_lines ++ [bottom]
  end

  defp row_line(cells, widths, theme, border, base) do
    pipe = {"│ ", border}

    inner =
      cells
      |> Enum.with_index()
      |> Enum.flat_map(fn {cell, i} ->
        w = Enum.at(widths, i, 1)
        runs = inline_to_runs(cell, theme, base) |> truncate_runs(w)
        pad = w - Style.visible_width(runs)
        runs ++ [{String.duplicate(" ", max(pad, 0)) <> " ", border}, {"│ ", border}]
      end)

    [pipe | inner]
  end

  defp fit_widths(widths, total, cols) do
    overhead = cols * 3 + 1
    avail = max(total - overhead, cols)

    if Enum.sum(widths) <= avail do
      widths
    else
      base = max(div(avail, cols), 1)
      Enum.map(widths, fn w -> min(w, base) end)
    end
  end
end
