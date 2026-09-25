defmodule Presentex.Terminal.Default do
  @moduledoc "Desktop backend: ANSI console output + raw-mode stdin."
  @behaviour Presentex.Terminal

  alias Presentex.Terminal.Console

  @impl true
  def setup(_opts) do
    _ = :os.cmd(~c"stty -echo -icanon min 1 time 0")
    Console.enter()
    %{}
  end

  @impl true
  def teardown(_state) do
    Console.leave()
    _ = :os.cmd(~c"stty sane")
    :ok
  end

  @impl true
  def read_key(_state), do: Console.read_stdin_key()

  @impl true
  def draw(_state, frame), do: Console.write(Console.render_frame(frame))
end
