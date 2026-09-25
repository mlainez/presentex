defmodule Presentex.Canvas do
  @moduledoc """
  A simple RGB pixel buffer held as a list of row binaries (`width * 3` bytes
  each). It can rasterize a text grid through a `Presentex.Font` and composite
  full-resolution images on top. Output is raw RGB, which the PNG encoder and
  the framebuffer packer both consume.

  Text rasterization caches per-`{row-bitmask, fg, bg}` pixel segments for the
  duration of a frame, so repeated glyphs/colors (most of a slide) are cheap.
  """

  import Bitwise
  alias Presentex.Font

  @type rgb :: {0..255, 0..255, 0..255}
  @type cell :: {non_neg_integer(), rgb(), rgb()}

  defstruct [:w, :h, :rows]

  @doc "A new canvas filled with `bg`."
  def new(w, h, bg) do
    row = :binary.copy(rgb_bin(bg), w)
    %__MODULE__{w: w, h: h, rows: List.duplicate(row, h)}
  end

  @doc "Concatenate rows into one RGB binary."
  def to_rgb(%__MODULE__{rows: rows}), do: IO.iodata_to_binary(rows)

  @doc """
  Rasterize a `grid` (list of rows, each a list of `{codepoint, fg, bg}` cells)
  into a standalone RGB block and blit it at `{x, y}`. `scale` enlarges the font.
  """
  def draw_grid(%__MODULE__{} = canvas, grid, font, scale, x, y) do
    cell_w = font.width * scale
    block_w = grid_width(grid) * cell_w
    block_rows = render_grid(grid, font, scale)
    blit_rows(canvas, block_rows, block_w, x, y)
  end

  @doc "Blit an RGB image (`iw` x `ih`) at `{x, y}`."
  def blit_rgb(%__MODULE__{} = canvas, rgb, iw, _ih, x, y) do
    stride = iw * 3
    rows = for <<r::binary-size(stride) <- rgb>>, do: r
    blit_rows(canvas, rows, iw, x, y)
  end

  # ── grid rasterization ──────────────────────────────────────────────────────
  defp grid_width([]), do: 0
  defp grid_width(grid), do: grid |> Enum.map(&length/1) |> Enum.max()

  defp render_grid([], _font, _scale), do: []

  defp render_grid(grid, font, scale) do
    width = grid_width(grid)
    glyph_cache = build_glyph_cache(grid, font)
    Process.put(:canvas_seg_cache, %{})

    try do
      Enum.flat_map(grid, fn cells ->
        cells = pad_cells(cells, width)
        render_grid_row(cells, font, scale, glyph_cache)
      end)
    after
      Process.delete(:canvas_seg_cache)
    end
  end

  defp pad_cells(cells, width) do
    cells ++
      List.duplicate(
        {32, Presentex.Theme.background(), Presentex.Theme.background()},
        width - length(cells)
      )
  end

  # Returns font.height*scale row binaries for one grid row of cells.
  defp render_grid_row(cells, font, scale, glyph_cache) do
    for fontrow <- 0..(font.height - 1) do
      row =
        cells
        |> Enum.map(fn {cp, fg, bg} ->
          rowbits = glyph_cache |> Map.fetch!(cp) |> Enum.at(fontrow, 0)
          segment(font, rowbits, fg, bg, scale)
        end)
        |> IO.iodata_to_binary()

      List.duplicate(row, scale)
    end
    |> List.flatten()
  end

  defp build_glyph_cache(grid, font) do
    grid
    |> List.flatten()
    |> Enum.map(fn {cp, _, _} -> cp end)
    |> Enum.uniq()
    |> Map.new(fn cp -> {cp, Font.rows(font, cp)} end)
  end

  # One glyph row -> RGB binary of width*scale pixels, memoized per {rowbits,fg,bg}.
  defp segment(font, rowbits, fg, bg, scale) do
    key = {rowbits, fg, bg, scale, font.width, font.bit_order}
    cache = Process.get(:canvas_seg_cache)

    case cache do
      %{^key => bin} ->
        bin

      _ ->
        fg_px = :binary.copy(rgb_bin(fg), scale)
        bg_px = :binary.copy(rgb_bin(bg), scale)

        bin =
          for x <- 0..(font.width - 1), into: <<>> do
            if Font.pixel?(font, rowbits, x), do: fg_px, else: bg_px
          end

        Process.put(:canvas_seg_cache, Map.put(cache, key, bin))
        bin
    end
  end

  # ── blitting ────────────────────────────────────────────────────────────────
  # Overwrite a region of the canvas with `src_rows` (each `src_w*3` bytes) at {x,y}.
  defp blit_rows(%__MODULE__{} = canvas, src_rows, src_w, x, y) do
    rows =
      canvas.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, ry} ->
        case index_for(src_rows, ry - y) do
          nil -> row
          src -> splice(row, src, src_w, x, canvas.w)
        end
      end)

    %{canvas | rows: rows}
  end

  defp index_for(_rows, i) when i < 0, do: nil
  defp index_for(rows, i), do: Enum.at(rows, i)

  # Overwrite `src_w` pixels of `row` starting at column `x` (clipped to canvas).
  defp splice(row, src, src_w, x, canvas_w) do
    clip_left = max(-x, 0)
    start = max(x, 0)
    visible = min(src_w - clip_left, canvas_w - start)

    if visible <= 0 do
      row
    else
      src_part = binary_part(src, clip_left * 3, visible * 3)
      pre = binary_part(row, 0, start * 3)
      post_start = (start + visible) * 3
      post = binary_part(row, post_start, byte_size(row) - post_start)
      <<pre::binary, src_part::binary, post::binary>>
    end
  end

  defp rgb_bin({r, g, b}), do: <<r &&& 255, g &&& 255, b &&& 255>>
end
