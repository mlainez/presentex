defmodule Presentex.Style do
  @moduledoc """
  A *run* is `{text :: binary, style :: map}`. Keeping text and style apart lets
  us word-wrap on the *visible* length (ignoring escape codes) and only emit
  ANSI at the very end. This avoids the classic bug where wrapping counts the
  bytes of `\\e[1m` as visible characters.
  """

  @type style :: map()
  @type run :: {binary(), style()}

  @doc "Turn a style map into the ANSI prefix string (no reset)."
  @spec ansi(style()) :: binary()
  def ansi(style) when is_map(style) do
    [
      flag(style, :bold, IO.ANSI.bright()),
      flag(style, :faint, IO.ANSI.faint()),
      flag(style, :italic, IO.ANSI.italic()),
      flag(style, :underline, IO.ANSI.underline()),
      flag(style, :reverse, IO.ANSI.reverse()),
      color(style[:fg], :fg),
      color(style[:bg], :bg)
    ]
    |> IO.iodata_to_binary()
  end

  defp flag(style, key, code), do: if(style[key], do: code, else: "")

  defp color(nil, _), do: ""

  # Truecolor (24-bit) — used by the half-block image renderer.
  defp color({r, g, b}, :fg), do: "\e[38;2;#{r};#{g};#{b}m"
  defp color({r, g, b}, :bg), do: "\e[48;2;#{r};#{g};#{b}m"

  # Named colors via IO.ANSI (e.g. :cyan, :light_blue / :red_background).
  defp color(name, :fg) when is_atom(name), do: ansi_fun(name)
  defp color(name, :bg) when is_atom(name), do: ansi_fun(:"#{name}_background")

  defp ansi_fun(name) do
    if function_exported?(IO.ANSI, name, 0), do: apply(IO.ANSI, name, []), else: ""
  end

  @doc "Render one run to a string wrapped in its style + reset."
  @spec render_run(run()) :: binary()
  def render_run({text, style}) do
    case ansi(style) do
      "" -> text
      prefix -> prefix <> text <> IO.ANSI.reset()
    end
  end

  @doc "Render a line (list of runs) to a single string."
  @spec render_line([run()]) :: binary()
  def render_line(runs), do: Enum.map_join(runs, "", &render_run/1)

  @doc "Total visible width of a list of runs."
  @spec visible_width([run()]) :: non_neg_integer()
  def visible_width(runs) do
    Enum.reduce(runs, 0, fn {t, _}, acc -> acc + String.length(t) end)
  end

  @doc """
  Word-wrap a list of runs to `width` visible columns, returning a list of
  lines (each a list of runs). Style is preserved across breaks. A single token
  longer than `width` is hard-broken.
  """
  @spec wrap([run()], pos_integer()) :: [[run()]]
  def wrap(runs, width) when width > 0 do
    runs
    |> to_tokens()
    |> pack(width)
    |> Enum.map(&merge_adjacent/1)
  end

  # Explode runs into {kind, text, style} tokens where kind is :word | :space.
  defp to_tokens(runs) do
    Enum.flat_map(runs, fn {text, style} ->
      Regex.scan(~r/\s+|\S+/u, text)
      |> Enum.map(fn [chunk] ->
        kind = if String.trim(chunk) == "", do: :space, else: :word
        {kind, chunk, style}
      end)
    end)
  end

  defp pack(tokens, width) do
    {lines, current, _len} =
      Enum.reduce(tokens, {[], [], 0}, fn
        {:space, _txt, _st}, {lines, [], 0} ->
          # drop leading spaces on a fresh line
          {lines, [], 0}

        {:space, _txt, st}, {lines, current, len} when len < width ->
          {lines, [{" ", st} | current], len + 1}

        {:space, _txt, _st}, acc ->
          acc

        {:word, txt, st}, {lines, current, len} ->
          wlen = String.length(txt)

          cond do
            len + wlen <= width ->
              {lines, [{txt, st} | current], len + wlen}

            wlen > width and current == [] ->
              # hard-break an over-long word
              {chunks, rest} = hard_break(txt, width)
              done = Enum.map(chunks, fn c -> [{c, st}] end)
              {Enum.reverse(done) ++ lines, [{rest, st}], String.length(rest)}

            true ->
              {[Enum.reverse(current) | lines], [{txt, st}], wlen}
          end
      end)

    finished = if current == [], do: lines, else: [Enum.reverse(current) | lines]
    Enum.reverse(finished)
  end

  defp hard_break(text, width) do
    graphemes = String.graphemes(text)
    full = div(length(graphemes), width)

    chunks =
      for i <- 0..(full - 1)//1, do: graphemes |> Enum.slice(i * width, width) |> Enum.join()

    rest = graphemes |> Enum.drop(full * width) |> Enum.join()
    {chunks, rest}
  end

  # Collapse neighbouring runs with identical style for tidier output.
  defp merge_adjacent(runs) do
    runs
    |> Enum.reduce([], fn
      {t, s}, [{pt, ps} | rest] when s == ps -> [{pt <> t, ps} | rest]
      run, acc -> [run | acc]
    end)
    |> Enum.reverse()
  end
end
