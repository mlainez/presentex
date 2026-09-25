defmodule Presentex.Presenter do
  @moduledoc """
  The run loop. Holds navigation state, turns key events into slide/pause moves,
  and hands a `Presentex.Frame` to the terminal backend to render.
  """

  alias Presentex.{Frame, Theme}
  alias Presentex.Parser.Deck

  defstruct [:deck, :theme, :term, :term_state, :index, :reveal, :margin, :base_dir]

  @margin 2

  @spec run(Deck.t(), keyword()) :: :ok
  def run(%Deck{slides: []}, _opts), do: IO.puts("Deck has no slides.")

  def run(%Deck{} = deck, opts) do
    term = Keyword.get(opts, :terminal, Presentex.Terminal.Default)
    term_opts = Keyword.get(opts, :terminal_opts, [])
    theme = Theme.get(Keyword.get(opts, :theme, :default))
    term_state = term.setup(term_opts)

    state = %__MODULE__{
      deck: deck,
      theme: theme,
      term: term,
      term_state: term_state,
      index: 0,
      reveal: 0,
      margin: Keyword.get(opts, :margin, @margin),
      base_dir: Keyword.get(opts, :base_dir, ".")
    }

    try do
      draw(state)
      loop(state)
    after
      term.teardown(term_state)
    end

    :ok
  end

  # ── event loop ──────────────────────────────────────────────────────────────
  defp loop(state) do
    case state.term.read_key(state.term_state) do
      :quit -> :ok
      :eof -> :ok
      key -> state |> handle(key) |> continue()
    end
  end

  defp continue(state) do
    draw(state)
    loop(state)
  end

  defp handle(state, key)
       when key in [:right, :down, :space, :enter, {:char, "n"}, {:char, "j"}] do
    advance(state)
  end

  defp handle(state, key) when key in [:left, :up, :backspace, {:char, "p"}, {:char, "k"}] do
    retreat(state)
  end

  defp handle(state, :home), do: %{state | index: 0, reveal: 0}
  defp handle(state, {:char, "g"}), do: %{state | index: 0, reveal: 0}
  defp handle(state, :end), do: goto_last(state)
  defp handle(state, {:char, "G"}), do: goto_last(state)
  defp handle(state, _), do: state

  defp advance(state) do
    slide = current(state)

    if state.reveal < slide.pause_count do
      %{state | reveal: state.reveal + 1}
    else
      %{state | index: min(state.index + 1, length(state.deck.slides) - 1), reveal: 0}
    end
  end

  defp retreat(state) do
    if state.reveal > 0 do
      %{state | reveal: state.reveal - 1}
    else
      prev = max(state.index - 1, 0)
      %{state | index: prev, reveal: Enum.at(state.deck.slides, prev).pause_count}
    end
  end

  defp goto_last(state) do
    last = length(state.deck.slides) - 1
    %{state | index: last, reveal: Enum.at(state.deck.slides, last).pause_count}
  end

  defp current(state), do: Enum.at(state.deck.slides, state.index)

  # ── drawing ─────────────────────────────────────────────────────────────────
  defp draw(state) do
    frame = %Frame{
      slide: current(state),
      theme: state.theme,
      index: state.index,
      total: length(state.deck.slides),
      title: Map.get(state.deck.meta, "title", ""),
      reveal: state.reveal,
      base_dir: state.base_dir,
      margin: state.margin
    }

    state.term.draw(state.term_state, frame)
  end
end
