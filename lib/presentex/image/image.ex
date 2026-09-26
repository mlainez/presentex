defmodule Presentex.Image do
  @moduledoc """
  Renders decoded images into the same `{text, style}` line format the rest of
  the renderer uses, so pictures flow through the normal pipeline and out via
  any `Presentex.Terminal`.

  The default technique is **half-blocks**: each character cell draws `▀` with
  the foreground set to the top pixel and the background to the bottom pixel,
  giving two vertical pixels per row of text. This needs only truecolor ANSI —
  no Kitty/sixel/iTerm protocol — so it works over a serial console and on any
  truecolor-capable display.

  For a framebuffer/HDMI display you may prefer to blit real pixels instead;
  `to_rgb/3` returns a scaled `{w, h, rgb_binary}` you can write to `/dev/fb0`
  (see the README).
  """

  alias Presentex.Image.PNG

  @upper "▀"

  @doc """
  Render the image at `path` into half-block lines fitted within `max_cols` x
  `max_rows` character cells. Returns `{:ok, lines}` or `{:error, reason}`.
  Results are memoized per `{path, cols, rows}` so redraws are cheap.
  """
  @spec render(Path.t(), pos_integer(), pos_integer()) ::
          {:ok, [[{binary(), map()}]]} | {:error, term()}
  def render(path, max_cols, max_rows) do
    key = {:presentex_img, path, max_cols, max_rows}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = do_render(path, max_cols, max_rows)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp do_render(path, max_cols, max_rows) do
    with {:ok, img} <- load(path) do
      {cols, rows, sampled} = sample(img, max_cols, max_rows)
      {:ok, to_lines(sampled, cols, rows)}
    end
  end

  @doc "Decoded `{width, height}` for a PNG, cached. Used to size image regions."
  @spec dimensions(Path.t()) :: {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  def dimensions(path) do
    with {:ok, img} <- load(path), do: {:ok, {img.width, img.height}}
  end

  # Decode (and cache) a PNG so repeated sizing/blitting doesn't re-inflate it.
  defp load(path) do
    key = {:presentex_png_decoded, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = PNG.decode_file(path)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  @doc """
  Return a scaled `{out_w, out_h, rgb}` pixel buffer (row-major `<<r,g,b,...>>`)
  for the image at `path`, fitting within `max_w` x `max_h` pixels. Intended for
  blitting to a framebuffer device on hardware.
  """
  @spec to_rgb(Path.t(), pos_integer(), pos_integer()) ::
          {:ok, {pos_integer(), pos_integer(), binary()}} | {:error, term()}
  def to_rgb(path, max_w, max_h) do
    with {:ok, img} <- load(path) do
      {ow, oh} = fit(img.width, img.height, max_w, max_h)

      rgb =
        for oy <- 0..(oh - 1), ox <- 0..(ow - 1), into: <<>> do
          {r, g, b} = pixel(img, sx(ox, ow, img.width), sy(oy, oh, img.height))
          <<r, g, b>>
        end

      {:ok, {ow, oh, rgb}}
    end
  end

  # ── scaling ─────────────────────────────────────────────────────────────────
  # Two pixels per character row, so the pixel grid is max_cols x (2*max_rows).
  defp sample(img, max_cols, max_rows) do
    {out_pw, out_ph} = fit(img.width, img.height, max_cols, max_rows * 2)
    cells_w = out_pw
    cells_h = div(out_ph + 1, 2)

    rows =
      for oy <- 0..(out_ph - 1) do
        for ox <- 0..(out_pw - 1) do
          pixel(img, sx(ox, out_pw, img.width), sy(oy, out_ph, img.height))
        end
      end

    {cells_w, cells_h, rows}
  end

  defp fit(w, h, max_w, max_h) do
    scale = min(max_w / w, max_h / h)
    scale = min(scale, 1.0) |> max(0.0)
    out_w = max(round(w * scale), 1)
    out_h = max(round(h * scale), 1)
    {out_w, out_h}
  end

  defp sx(ox, out_w, src_w), do: min(div(ox * src_w, out_w), src_w - 1)
  defp sy(oy, out_h, src_h), do: min(div(oy * src_h, out_h), src_h - 1)

  defp pixel(%{pixels: px, width: w}, x, y) do
    off = (y * w + x) * 3
    <<_::binary-size(^off), r, g, b, _::binary>> = px
    {r, g, b}
  end

  # ── half-block lines ────────────────────────────────────────────────────────
  defp to_lines(rows, cells_w, cells_h) do
    row_vec = List.to_tuple(rows)
    n = tuple_size(row_vec)

    for cy <- 0..(cells_h - 1) do
      top = elem(row_vec, min(2 * cy, n - 1))
      bottom = if 2 * cy + 1 < n, do: elem(row_vec, 2 * cy + 1), else: top

      for cx <- 0..(cells_w - 1) do
        {@upper, %{fg: Enum.at(top, cx), bg: Enum.at(bottom, cx)}}
      end
    end
  end
end
