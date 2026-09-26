defmodule Presentex.Input.Evdev do
  @moduledoc """
  Reads Linux input events from `/dev/input/event*` and maps them to
  `Presentex.Terminal` keys. Works with any evdev device — a USB presenter
  clicker, a gamepad, a keyboard, or a D-pad controller.

  ## The struct, and why endianness matters

  A `struct input_event` is a `timeval` followed by `__u16 type`, `__u16 code`,
  `__s32 value`. The timeval size varies (8 bytes with 32-bit `long`, 16 with
  64-bit/time64), but `type`/`code`/`value` are always the **last 8 bytes**, so
  we only need the total record size and the byte order. Most modern hosts are
  64-bit little-endian (`:le64`); 32-bit little-endian uses `:le32`. Big-endian
  targets (e.g. 32-bit PowerPC) use `:be32`/`:be64`. Confirm the record size on
  your kernel with `evtest` if events look wrong (try 16 vs 24).

  Override any of it:

      Presentex.run("talk.md",
        terminal: Presentex.Terminal.Evdev,
        terminal_opts: [device: "/dev/input/event0", layout: :le64])
  """

  # event types
  @ev_key 1
  @ev_abs 3

  # absolute axes (D-pad commonly reports here)
  @abs_hat0x 16
  @abs_hat0y 17

  # default button code -> action map. Codes follow <linux/input-event-codes.h>;
  # a given device's driver may pick different codes, so this is overridable.
  @default_buttons %{
    0x220 => :up,
    0x221 => :down,
    0x222 => :left,
    0x223 => :right,
    # BTN_SOUTH (A) advance, BTN_EAST (B) back
    0x130 => :space,
    0x131 => :backspace,
    # BTN_START (+) advance, BTN_SELECT (-) back, BTN_MODE (home) quit
    0x13B => :space,
    0x13A => :backspace,
    0x13C => :quit
  }

  @type layout :: %{event_size: pos_integer(), endian: :big | :little, buttons: map()}

  @doc """
  Named layout presets, by record size and byte order:

    * `:le64` - 24-byte little-endian (most 64-bit hosts; the default)
    * `:le32` - 16-byte little-endian (32-bit hosts)
    * `:be64` - 24-byte big-endian
    * `:be32` - 16-byte big-endian (e.g. 32-bit PowerPC)
  """
  @spec layout(atom()) :: layout()
  def layout(:le64), do: %{event_size: 24, endian: :little, buttons: @default_buttons}
  def layout(:le32), do: %{event_size: 16, endian: :little, buttons: @default_buttons}
  def layout(:be64), do: %{event_size: 24, endian: :big, buttons: @default_buttons}
  def layout(:be32), do: %{event_size: 16, endian: :big, buttons: @default_buttons}
  def layout(_), do: layout(:le64)

  @doc "Build a layout from terminal opts (`:layout` atom or map, optional `:buttons`)."
  @spec resolve_layout(keyword()) :: layout()
  def resolve_layout(opts) do
    base =
      case Keyword.get(opts, :layout, :le64) do
        l when is_atom(l) -> layout(l)
        %{} = custom -> custom
      end

    case Keyword.get(opts, :buttons) do
      nil -> base
      buttons -> Map.put(base, :buttons, buttons)
    end
  end

  @doc "Open an input device for raw reading."
  @spec open(Path.t()) :: {:ok, term()} | {:error, term()}
  def open(path), do: :file.open(path, [:read, :raw, :binary])

  @doc "Close the device."
  def close(fd), do: :file.close(fd)

  @doc """
  Block until an input event maps to a navigation key, then return it.
  Releases, repeats of non-navigation buttons, and SYN events are skipped.
  """
  @spec read_key(term(), layout()) :: Presentex.Terminal.key()
  def read_key(fd, layout) do
    case read_exact(fd, layout.event_size) do
      {:ok, bin} ->
        case map_event(decode(bin, layout.endian), layout.buttons) do
          :ignore -> read_key(fd, layout)
          key -> key
        end

      :eof ->
        :eof

      {:error, _} ->
        :eof
    end
  end

  @doc "Decode one raw event record into `{type, code, value}`."
  @spec decode(binary(), :big | :little) :: {non_neg_integer(), non_neg_integer(), integer()}
  def decode(bin, endian) when byte_size(bin) >= 8 do
    skip = byte_size(bin) - 8
    <<_::binary-size(^skip), tail::binary-size(8)>> = bin

    case endian do
      :big ->
        <<t::big-16, c::big-16, v::big-signed-32>> = tail
        {t, c, v}

      :little ->
        <<t::little-16, c::little-16, v::little-signed-32>> = tail
        {t, c, v}
    end
  end

  @doc "Map a decoded `{type, code, value}` to a key, or `:ignore`."
  @spec map_event({non_neg_integer(), non_neg_integer(), integer()}, map()) ::
          Presentex.Terminal.key() | :ignore
  def map_event({@ev_abs, @abs_hat0y, v}, _buttons) when v < 0, do: :up
  def map_event({@ev_abs, @abs_hat0y, v}, _buttons) when v > 0, do: :down
  def map_event({@ev_abs, @abs_hat0x, v}, _buttons) when v < 0, do: :left
  def map_event({@ev_abs, @abs_hat0x, v}, _buttons) when v > 0, do: :right
  # key press (value 1) or autorepeat (value 2); ignore release (0)
  def map_event({@ev_key, code, v}, buttons) when v != 0, do: Map.get(buttons, code, :ignore)
  def map_event(_event, _buttons), do: :ignore

  # ── helpers ─────────────────────────────────────────────────────────────────
  defp read_exact(fd, n), do: read_exact(fd, n, <<>>)

  defp read_exact(_fd, 0, acc), do: {:ok, acc}

  defp read_exact(fd, n, acc) do
    case :file.read(fd, n) do
      {:ok, data} ->
        got = byte_size(data)
        if got >= n, do: {:ok, acc <> data}, else: read_exact(fd, n - got, acc <> data)

      :eof ->
        :eof

      other ->
        other
    end
  end
end
