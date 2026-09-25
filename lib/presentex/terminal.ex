defmodule Presentex.Terminal do
  @moduledoc """
  The I/O seam. A backend sets up its device, reads keys, and draws a
  `Presentex.Frame`. Because the loop hands over a frame (a slide model) rather
  than bytes, each backend composes its own output:

    * `Presentex.Terminal.Default`     - console output + raw-mode stdin.
    * `Presentex.Terminal.Evdev`       - console output + evdev input device.
    * `Presentex.Terminal.Framebuffer` - pixel output to `/dev/fb0` + stdin or
      evdev input: crisp truecolor text and full-resolution images, independent
      of the text console's color depth.

  `setup/1` receives `terminal_opts` and returns the state threaded through.
  """

  @type state :: term()

  @type key ::
          :up
          | :down
          | :left
          | :right
          | :enter
          | :space
          | :backspace
          | :home
          | :end
          | :quit
          | {:char, binary()}
          | :unknown
          | :eof

  @callback setup(keyword()) :: state()
  @callback teardown(state()) :: :ok
  @callback read_key(state()) :: key()
  @callback draw(state(), Presentex.Frame.t()) :: :ok
end
