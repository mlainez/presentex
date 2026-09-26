defmodule Presentex.Image.PNG do
  @moduledoc """
  Minimal PNG decoder in pure Elixir. Decompression uses ERTS's built-in
  `:zlib` (part of the runtime, not a hex/native dependency), so this works on a
  Nerves target with no cross-compilation.

  Supports 8-bit-per-channel, non-interlaced PNGs in grayscale (color type 0),
  RGB (2), palette (3), and RGBA (6). Returns `{:ok, %{width, height, pixels}}`
  where `pixels` is a row-major `RGB` binary (`<<r, g, b, ...>>`), or
  `{:error, reason}`. JPEG and other formats aren't supported — convert to PNG.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type image :: %{width: pos_integer(), height: pos_integer(), pixels: binary()}

  @spec decode(binary()) :: {:ok, image()} | {:error, term()}
  def decode(<<@signature, rest::binary>>) do
    with {:ok, chunks} <- read_chunks(rest, []),
         {:ok, ihdr} <- find_ihdr(chunks),
         :ok <- supported?(ihdr),
         idat <- collect_idat(chunks),
         {:ok, raw} <- inflate(idat),
         {:ok, pixels} <- to_rgb(raw, ihdr, palette(chunks)) do
      {:ok, %{width: ihdr.width, height: ihdr.height, pixels: pixels}}
    end
  end

  def decode(_), do: {:error, :not_a_png}

  @spec decode_file(Path.t()) :: {:ok, image()} | {:error, term()}
  def decode_file(path) do
    case File.read(path) do
      {:ok, bin} -> decode(bin)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encode an 8-bit RGB image (`width` x `height`, row-major `<<r,g,b,...>>`) to a
  PNG binary. Uses `:zlib` and filter type 0. Handy for previewing/exporting
  slides without hardware.
  """
  @spec encode(pos_integer(), pos_integer(), binary()) :: binary()
  def encode(width, height, rgb) do
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>
    stride = width * 3

    raw =
      for <<row::binary-size(^stride) <- rgb>>, into: <<>> do
        <<0, row::binary>>
      end

    idat = :zlib.compress(raw)
    @signature <> chunk("IHDR", ihdr) <> chunk("IDAT", idat) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    body = type <> data
    <<byte_size(data)::32, body::binary, :erlang.crc32(body)::32>>
  end

  # ── chunk reading ───────────────────────────────────────────────────────────
  defp read_chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ) do
    read_chunks(rest, [{type, data} | acc])
  end

  defp read_chunks(_, acc), do: {:ok, Enum.reverse(acc)}

  defp find_ihdr(chunks) do
    case List.keyfind(chunks, "IHDR", 0) do
      {"IHDR", <<width::32, height::32, bit_depth, color_type, _compress, _filter, interlace>>} ->
        {:ok,
         %{
           width: width,
           height: height,
           bit_depth: bit_depth,
           color_type: color_type,
           interlace: interlace
         }}

      _ ->
        {:error, :missing_ihdr}
    end
  end

  defp supported?(%{bit_depth: 8, interlace: 0, color_type: ct}) when ct in [0, 2, 3, 6], do: :ok

  defp supported?(ihdr),
    do: {:error, {:unsupported, Map.take(ihdr, [:bit_depth, :color_type, :interlace])}}

  defp palette(chunks) do
    case List.keyfind(chunks, "PLTE", 0) do
      {"PLTE", data} -> data
      _ -> nil
    end
  end

  defp collect_idat(chunks) do
    chunks
    |> Enum.filter(fn {type, _} -> type == "IDAT" end)
    |> Enum.map(fn {_, data} -> data end)
    |> IO.iodata_to_binary()
  end

  defp inflate(data) do
    {:ok, :zlib.uncompress(data)}
  rescue
    _ -> {:error, :inflate_failed}
  end

  # ── unfilter + colorize ─────────────────────────────────────────────────────
  defp channels(0), do: 1
  defp channels(2), do: 3
  defp channels(3), do: 1
  defp channels(6), do: 4

  defp to_rgb(raw, ihdr, plte) do
    bpp = channels(ihdr.color_type)
    stride = ihdr.width * bpp

    unfiltered = unfilter(raw, stride, bpp, ihdr.height)
    rgb = recolor(unfiltered, ihdr.color_type, plte)
    {:ok, rgb}
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  # Walk scanlines: each is a filter byte followed by `stride` data bytes.
  defp unfilter(raw, stride, bpp, height) do
    do_unfilter(raw, stride, bpp, height, <<>>, [])
  end

  defp do_unfilter(_raw, _stride, _bpp, 0, _prev, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp do_unfilter(<<filter, rest::binary>>, stride, bpp, rows_left, prev, acc) do
    <<line::binary-size(^stride), tail::binary>> = rest
    decoded = apply_filter(filter, line, prev, bpp)
    do_unfilter(tail, stride, bpp, rows_left - 1, decoded, [decoded | acc])
  end

  defp apply_filter(0, line, _prev, _bpp), do: line

  defp apply_filter(type, line, prev, bpp) do
    recon(type, line, prev, bpp, 0, <<>>)
  end

  defp recon(_type, <<>>, _prev, _bpp, _i, out), do: out

  defp recon(type, <<x, rest::binary>>, prev, bpp, i, out) do
    a = byte_at(out, i - bpp)
    b = byte_at(prev, i)
    c = byte_at(prev, i - bpp)

    value =
      case type do
        1 -> x + a
        2 -> x + b
        3 -> x + div(a + b, 2)
        4 -> x + paeth(a, b, c)
      end

    recon(type, rest, prev, bpp, i + 1, <<out::binary, rem(value, 256)>>)
  end

  defp byte_at(_bin, i) when i < 0, do: 0

  defp byte_at(bin, i) do
    if i < byte_size(bin), do: :binary.at(bin, i), else: 0
  end

  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # Convert unfiltered channel data into a flat RGB binary.
  defp recolor(data, 2, _plte), do: data

  defp recolor(data, 0, _plte) do
    for <<g <- data>>, into: <<>>, do: <<g, g, g>>
  end

  defp recolor(data, 6, _plte) do
    for <<r, g, b, _a <- data>>, into: <<>>, do: <<r, g, b>>
  end

  defp recolor(data, 3, plte) do
    for <<idx <- data>>, into: <<>> do
      <<_::binary-size(^idx * 3), r, g, b, _::binary>> = plte
      <<r, g, b>>
    end
  end
end
