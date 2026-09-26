defmodule Presentex.Framebuffer do
  @moduledoc """
  Blit a PNG straight to a Linux framebuffer device (`/dev/fb0`). Use this when
  the half-block console renderer is limited by the text console's color depth —
  here you write real pixels.

  You must tell it the framebuffer geometry, since that's hardware-specific.
  Read it on the device with `fbset` or from
  `/sys/class/graphics/fb0/{virtual_size,bits_per_pixel,stride}`.

      Presentex.Framebuffer.blit("slide.png",
        device: "/dev/fb0",
        bytes_per_line: 1280 * 4,   # fb_fix_screeninfo.line_length
        format: :xrgb8888,          # or :rgb565
        x: 100, y: 80,
        max_w: 1000, max_h: 700)

  Pure Elixir + `:file` — no native deps. Decoding uses `Presentex.Image.PNG`.
  """

  alias Presentex.Image
  import Bitwise

  @spec blit(Path.t(), keyword()) :: :ok | {:error, term()}
  def blit(path, opts) do
    device = Keyword.get(opts, :device, "/dev/fb0")
    line_bytes = Keyword.fetch!(opts, :bytes_per_line)
    format = Keyword.get(opts, :format, :xrgb8888)
    x = Keyword.get(opts, :x, 0)
    y = Keyword.get(opts, :y, 0)
    max_w = Keyword.get(opts, :max_w, 1920)
    max_h = Keyword.get(opts, :max_h, 1080)

    with {:ok, {w, h, rgb}} <- Image.to_rgb(path, max_w, max_h),
         {:ok, fd} <- :file.open(device, [:write, :raw, :binary]) do
      bpp = bytes_per_pixel(format)

      try do
        write_rows(fd, rgb, w, h, format, bpp, line_bytes, x, y)
      after
        :file.close(fd)
      end
    end
  end

  @doc "Pack one scaled image's RGB binary into raw framebuffer rows (for tests/preview)."
  @spec encode(binary(), pos_integer(), atom()) :: binary()
  def encode(rgb, width, format) do
    pack_row(rgb, width, format, <<>>)
  end

  @doc """
  Pack a full RGB frame (`w` x `h`) into a device buffer: each row packed to
  `format` and zero-padded to `line_bytes` (the framebuffer stride), so the whole
  frame can be written with a single `pwrite` at offset 0.
  """
  @spec pack_frame(binary(), pos_integer(), pos_integer(), atom(), pos_integer()) :: binary()
  def pack_frame(rgb, w, _h, format, line_bytes) do
    row_bytes = w * 3
    packed_w = w * bytes_per_pixel(format)
    pad = max(line_bytes - packed_w, 0)
    padding = :binary.copy(<<0>>, pad)

    for <<row::binary-size(^row_bytes) <- rgb>>, into: <<>> do
      <<pack_row(row, w, format, <<>>)::binary, padding::binary>>
    end
  end

  defp write_rows(_fd, _rgb, _w, 0, _fmt, _bpp, _lb, _x, _y), do: :ok

  defp write_rows(fd, rgb, w, rows_left, format, bpp, line_bytes, x, y) do
    row_bytes = w * 3
    <<row::binary-size(^row_bytes), rest::binary>> = rgb
    packed = pack_row(row, w, format, <<>>)
    offset = y * line_bytes + x * bpp
    :ok = :file.pwrite(fd, offset, packed)
    write_rows(fd, rest, w, rows_left - 1, format, bpp, line_bytes, x, y + 1)
  end

  defp pack_row(<<>>, _w, _format, acc), do: acc

  defp pack_row(<<r, g, b, rest::binary>>, w, :xrgb8888, acc) do
    # little-endian XRGB in memory = bytes B, G, R, X
    pack_row(rest, w, :xrgb8888, <<acc::binary, b, g, r, 0>>)
  end

  defp pack_row(<<r, g, b, rest::binary>>, w, :rgb565, acc) do
    value = r >>> 3 <<< 11 ||| g >>> 2 <<< 5 ||| b >>> 3
    pack_row(rest, w, :rgb565, <<acc::binary, value::little-16>>)
  end

  defp bytes_per_pixel(:xrgb8888), do: 4
  defp bytes_per_pixel(:rgb565), do: 2
end
