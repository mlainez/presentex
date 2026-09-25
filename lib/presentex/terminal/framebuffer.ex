defmodule Presentex.Terminal.Framebuffer do
  @moduledoc """
  Draws each slide as pixels straight to a Linux framebuffer (`/dev/fb0`) — crisp
  truecolor text via a bitmap font and full-resolution images — then reads
  navigation from stdin or an evdev input device. The look no longer depends on
  the text console's (often 16-color) capabilities.

  Options (`terminal_opts:`):

    * `:device`       - framebuffer device (default `"/dev/fb0"`)
    * `:width_px`     - screen width in pixels (default 1280)
    * `:height_px`    - screen height in pixels (default 720)
    * `:bytes_per_line` - framebuffer stride; defaults to `width_px * bpp`
    * `:format`       - `:xrgb8888` (default) or `:rgb565`
    * `:scale`        - font magnification (default 2)
    * `:margin`       - margin in cells (default 3)
    * `:font`         - a `%Presentex.Font{}` (default the built-in 8x8); load a
      PSF font with `Presentex.Font.PSF.load/1` for a crisp high-res look
    * `:input`        - `:stdin` (default) or `:evdev`
    * `:input_device`, `:layout`, `:buttons` - evdev input config (see
      `Presentex.Input.Evdev`)

  Read your screen geometry with `fbset` or from `/sys/class/graphics/fb0/`.
  """
  @behaviour Presentex.Terminal

  alias Presentex.{Pixel, Framebuffer, Font}
  alias Presentex.Terminal.Console
  alias Presentex.Input.Evdev

  @impl true
  def setup(opts) do
    device = Keyword.get(opts, :device, "/dev/fb0")
    format = Keyword.get(opts, :format, :xrgb8888)
    width_px = Keyword.get(opts, :width_px, 1280)
    height_px = Keyword.get(opts, :height_px, 720)
    bpp = if format == :rgb565, do: 2, else: 4
    line_bytes = Keyword.get(opts, :bytes_per_line, width_px * bpp)
    font = Keyword.get(opts, :font, Font.Builtin.font())

    state = %{
      device: device,
      fd: open_fb!(device),
      format: format,
      width_px: width_px,
      height_px: height_px,
      line_bytes: line_bytes,
      scale: Keyword.get(opts, :scale, 2),
      margin: Keyword.get(opts, :margin, 3),
      font: font,
      input: input_setup(opts)
    }

    state
  end

  defp open_fb!(device) do
    case :file.open(device, [:write, :raw, :binary]) do
      {:ok, fd} -> fd
      {:error, reason} -> raise "Framebuffer: cannot open #{device}: #{inspect(reason)}"
    end
  end

  defp input_setup(opts) do
    case Keyword.get(opts, :input, :stdin) do
      :evdev ->
        device = Keyword.get(opts, :input_device, "/dev/input/event0")
        layout = Evdev.resolve_layout(opts)

        case Evdev.open(device) do
          {:ok, fd} -> {:evdev, fd, layout}
          {:error, reason} -> raise "Framebuffer input: cannot open #{device}: #{inspect(reason)}"
        end

      _ ->
        _ = :os.cmd(~c"stty -echo -icanon min 1 time 0")
        :stdin
    end
  end

  @impl true
  def teardown(state) do
    :file.close(state.fd)

    case state.input do
      {:evdev, fd, _} -> Evdev.close(fd)
      :stdin -> :os.cmd(~c"stty sane")
    end

    :ok
  end

  @impl true
  def read_key(%{input: {:evdev, fd, layout}}), do: Evdev.read_key(fd, layout)
  def read_key(%{input: :stdin}), do: Console.read_stdin_key()

  @impl true
  def draw(state, frame) do
    {rgb, w, h} =
      Pixel.render(frame.slide, frame.theme,
        font: state.font,
        width_px: state.width_px,
        height_px: state.height_px,
        scale: state.scale,
        margin: state.margin,
        reveal: frame.reveal,
        base_dir: frame.base_dir,
        index: frame.index,
        total: frame.total,
        title: frame.title
      )

    buffer = Framebuffer.pack_frame(rgb, w, h, state.format, state.line_bytes)
    :file.pwrite(state.fd, 0, buffer)
    :ok
  end
end
