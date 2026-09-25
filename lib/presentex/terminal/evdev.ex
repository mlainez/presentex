defmodule Presentex.Terminal.Evdev do
  @moduledoc """
  ANSI console output with input from a Linux input device
  (`/dev/input/event*`) — a presenter clicker, gamepad, or keyboard.

  Options: `:device` (default `/dev/input/event0`), `:layout`
  (`:le64` | `:le32` | `:be64` | `:be32` | custom map), `:buttons`
  (override code map).
  """
  @behaviour Presentex.Terminal

  alias Presentex.Terminal.Console
  alias Presentex.Input.Evdev

  @impl true
  def setup(opts) do
    device = Keyword.get(opts, :device, "/dev/input/event0")
    layout = Evdev.resolve_layout(opts)
    Console.enter()

    case Evdev.open(device) do
      {:ok, fd} ->
        %{fd: fd, layout: layout}

      {:error, reason} ->
        Console.leave()
        raise "Presentex.Terminal.Evdev: cannot open #{device}: #{inspect(reason)}"
    end
  end

  @impl true
  def teardown(%{fd: fd}) do
    Evdev.close(fd)
    Console.leave()
    :ok
  end

  @impl true
  def read_key(%{fd: fd, layout: layout}), do: Evdev.read_key(fd, layout)

  @impl true
  def draw(_state, frame), do: Console.write(Console.render_frame(frame))
end
