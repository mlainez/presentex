defmodule Presentex.Font do
  @moduledoc """
  A bitmap font: `width` x `height` pixels per glyph, and a `glyphs` map from
  Unicode codepoint to row data. Each glyph is `height` rows; a row is an
  integer bitmask. `bit_order` says which bit is the leftmost pixel:

    * `:lsb_left` - bit 0 is leftmost (the built-in font8x8 encoding)
    * `:msb_left` - bit `width - 1` is leftmost (typical PSF encoding)

  A glyph value may be a binary (one byte per row, for width <= 8) or a list of
  row integers (for wider PSF fonts). Missing glyphs render blank.
  """

  import Bitwise

  defstruct width: 8, height: 8, glyphs: %{}, bit_order: :lsb_left

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          glyphs: %{optional(non_neg_integer()) => binary() | [non_neg_integer()]},
          bit_order: :lsb_left | :msb_left
        }

  @doc "Row bitmasks for a codepoint (a list of `height` integers); blanks if absent."
  @spec rows(t(), non_neg_integer()) :: [non_neg_integer()]
  def rows(%__MODULE__{} = font, codepoint) do
    case Map.get(font.glyphs, codepoint) do
      nil -> List.duplicate(0, font.height)
      bin when is_binary(bin) -> :binary.bin_to_list(bin)
      list when is_list(list) -> list
    end
  end

  @doc "Is pixel column `x` (0 = leftmost) set in this row bitmask?"
  @spec pixel?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def pixel?(%__MODULE__{bit_order: :lsb_left}, row, x), do: (row >>> x &&& 1) == 1

  def pixel?(%__MODULE__{bit_order: :msb_left, width: w}, row, x),
    do: (row >>> (w - 1 - x) &&& 1) == 1

  @doc "Have a glyph for this codepoint?"
  def has?(%__MODULE__{} = font, codepoint), do: Map.has_key?(font.glyphs, codepoint)
end
