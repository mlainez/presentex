defmodule Presentex.Font.PSF do
  @moduledoc """
  Load a PC Screen Font (PSF1 or PSF2) into a `Presentex.Font`. Drop a crisp
  console font (e.g. Spleen or Terminus, which ship as PSF2) into `priv/fonts/`
  and use a larger glyph for a sharp look on a projector:

      {:ok, font} = Presentex.Font.PSF.load("priv/fonts/spleen-16x32.psfu")
      Presentex.run("talk.md",
        terminal: Presentex.Terminal.Framebuffer,
        terminal_opts: [font: font, ...])

  PSF2's embedded unicode table is parsed when present, so box-drawing and block
  glyphs map to the right codepoints. PSF bytes are MSB-left.
  """

  import Bitwise
  alias Presentex.Font

  @psf1_magic <<0x36, 0x04>>
  @psf2_magic <<0x72, 0xB5, 0x4A, 0x86>>

  @spec load(Path.t()) :: {:ok, Font.t()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, bin} -> parse(bin)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse(binary()) :: {:ok, Font.t()} | {:error, term()}
  def parse(@psf2_magic <> _ = bin) do
    <<_magic::32, _version::little-32, headersize::little-32, flags::little-32, length::little-32,
      charsize::little-32, height::little-32, width::little-32, _::binary>> = bin

    rest = binary_part(bin, headersize, byte_size(bin) - headersize)
    glyph_bytes = length * charsize
    <<glyph_data::binary-size(glyph_bytes), unicode::binary>> = rest

    rows_per = height
    bytes_per_row = div(charsize, rows_per)
    glyphs = split_glyphs(glyph_data, charsize, rows_per, bytes_per_row)

    index_to_cp = if (flags &&& 1) == 1, do: parse_unicode_table(unicode), else: %{}
    {:ok, build(glyphs, index_to_cp, width, height)}
  rescue
    e -> {:error, {:psf2_parse, e}}
  end

  def parse(@psf1_magic <> <<mode, charsize>> <> rest) do
    count = if (mode &&& 1) == 1, do: 512, else: 256
    glyph_bytes = count * charsize
    <<glyph_data::binary-size(glyph_bytes), _unicode::binary>> = rest

    glyphs = split_glyphs(glyph_data, charsize, charsize, 1)
    {:ok, build(glyphs, %{}, 8, charsize)}
  rescue
    e -> {:error, {:psf1_parse, e}}
  end

  def parse(_), do: {:error, :not_a_psf}

  # ── helpers ─────────────────────────────────────────────────────────────────
  defp split_glyphs(data, charsize, rows_per, bytes_per_row) do
    for <<glyph::binary-size(charsize) <- data>> do
      for <<row::binary-size(bytes_per_row) <- glyph>>, into: [] do
        :binary.decode_unsigned(row, :big)
      end
      |> Enum.take(rows_per)
    end
  end

  # Build glyph map keyed by codepoint. With a unicode table, map each codepoint
  # to its glyph index; otherwise assume index == codepoint.
  defp build(glyphs, index_to_cp, width, height) do
    glyph_vec = List.to_tuple(glyphs)
    n = tuple_size(glyph_vec)

    by_cp =
      if map_size(index_to_cp) > 0 do
        for {cp, idx} <- index_to_cp, idx < n, into: %{}, do: {cp, elem(glyph_vec, idx)}
      else
        for idx <- 0..(n - 1), into: %{}, do: {idx, elem(glyph_vec, idx)}
      end

    %Font{width: width, height: height, glyphs: by_cp, bit_order: :msb_left}
  end

  # PSF2 unicode table: per glyph index, UTF-8 codepoints, 0xFE = sequence sep,
  # 0xFF = end of entry. We record the first codepoint of each entry.
  defp parse_unicode_table(bin), do: parse_unicode_table(bin, 0, %{}, true)

  defp parse_unicode_table(<<>>, _idx, acc, _first?), do: acc

  defp parse_unicode_table(<<0xFF, rest::binary>>, idx, acc, _first?) do
    parse_unicode_table(rest, idx + 1, acc, true)
  end

  defp parse_unicode_table(<<0xFE, rest::binary>>, idx, acc, _first?) do
    # multi-codepoint sequence separator; stop recording for this entry
    parse_unicode_table(rest, idx, acc, false)
  end

  defp parse_unicode_table(bin, idx, acc, first?) do
    {cp, rest} = take_utf8(bin)

    acc =
      if first? and cp != nil and not Map.has_key?(acc, cp),
        do: Map.put(acc, cp, idx),
        else: acc

    parse_unicode_table(rest, idx, acc, false)
  end

  defp take_utf8(<<cp::utf8, rest::binary>>), do: {cp, rest}
  defp take_utf8(<<_byte, rest::binary>>), do: {nil, rest}
  defp take_utf8(<<>>), do: {nil, <<>>}
end
