defmodule Presentex.Parser do
  @moduledoc """
  A small, self-contained Markdown parser for the presentation subset. No hex
  dependencies — it compiles to portable BEAM bytecode, which is the whole point
  for running inside Nerves on an exotic target (no C, no cross-compilation).

  Supports: front matter, slide separators (`<!-- end_slide -->` or a `---`
  line), headings, paragraphs, fenced code blocks, ordered/unordered lists with
  one level of nesting, blockquotes, horizontal rules (`***`/`___`), images,
  simple pipe tables, and `<!-- pause -->` incremental reveals. Inline:
  `**strong**`, `*em*`, `` `code` ``, and `[text](url)` links.
  """

  defmodule Deck do
    @moduledoc false
    defstruct meta: %{}, slides: []
  end

  @type inline :: [{atom(), term()}]
  @type block :: tuple() | :hr | :pause

  @doc "Parse a markdown string into a `%Deck{}`."
  @spec parse(binary()) :: %Deck{}
  def parse(source) do
    {meta, body} = split_front_matter(source)

    slides =
      body
      |> split_slides()
      |> Enum.map(&parse_slide/1)
      |> Enum.reject(&(&1.blocks == []))

    %Deck{meta: meta, slides: slides}
  end

  @doc "Parse a file path into a `%Deck{}`."
  @spec parse_file(Path.t()) :: %Deck{}
  def parse_file(path), do: path |> File.read!() |> parse()

  # ── front matter ──────────────────────────────────────────────────────────
  defp split_front_matter("---\n" <> rest) do
    case String.split(rest, ~r/\n---\n/, parts: 2) do
      [front, body] -> {parse_meta(front), body}
      [_only] -> {%{}, "---\n" <> rest}
    end
  end

  defp split_front_matter(source), do: {%{}, source}

  defp parse_meta(front) do
    front
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  # ── slide splitting ─────────────────────────────────────────────────────────
  defp split_slides(body) do
    body
    |> String.split(~r/^\s*(?:<!--\s*end_slide\s*-->|---)\s*$/m)
    |> Enum.map(&String.trim/1)
  end

  # ── per-slide block parsing ─────────────────────────────────────────────────
  defmodule Slide do
    @moduledoc false
    # blocks: list of block tuples. pause_count: number of <!-- pause --> markers.
    defstruct blocks: [], center?: false, pause_count: 0
  end

  defp parse_slide(text) do
    center? = String.contains?(text, "<!-- center -->")
    lines = String.split(text, "\n")
    blocks = parse_blocks(lines, [])
    pause_count = Enum.count(blocks, &(&1 == :pause))
    %Slide{blocks: blocks, center?: center?, pause_count: pause_count}
  end

  defp parse_blocks([], acc), do: Enum.reverse(acc)

  defp parse_blocks([line | rest], acc) do
    cond do
      blank?(line) ->
        parse_blocks(rest, acc)

      fence?(line) ->
        {block, rest2} = take_code(line, rest)
        parse_blocks(rest2, [block | acc])

      heading = match_heading(line) ->
        parse_blocks(rest, [heading | acc])

      hr?(line) ->
        parse_blocks(rest, [:hr | acc])

      pause?(line) ->
        parse_blocks(rest, [:pause | acc])

      comment_only?(line) ->
        parse_blocks(rest, acc)

      img = match_image(line) ->
        parse_blocks(rest, [img | acc])

      table_start?(line, rest) ->
        {block, rest2} = take_table([line | rest])
        parse_blocks(rest2, [block | acc])

      quote?(line) ->
        {block, rest2} = take_quote([line | rest])
        parse_blocks(rest2, [block | acc])

      list_item(line) ->
        {block, rest2} = take_list([line | rest])
        parse_blocks(rest2, [block | acc])

      true ->
        {block, rest2} = take_paragraph([line | rest])
        parse_blocks(rest2, [block | acc])
    end
  end

  # ── block matchers ──────────────────────────────────────────────────────────
  defp blank?(line), do: String.trim(line) == ""
  defp fence?(line), do: Regex.match?(~r/^\s*```/, line)
  defp hr?(line), do: Regex.match?(~r/^\s*(\*\*\*+|___+)\s*$/, line)
  defp pause?(line), do: Regex.match?(~r/^\s*<!--\s*pause\s*-->\s*$/, line)
  defp comment_only?(line), do: Regex.match?(~r/^\s*<!--.*-->\s*$/, line)

  defp match_heading(line) do
    case Regex.run(~r/^([#]{1,6})\s+(.*)$/, line) do
      [_, hashes, text] -> {:heading, String.length(hashes), parse_inline(text)}
      _ -> nil
    end
  end

  defp match_image(line) do
    case Regex.run(~r/^\s*!\[([^\]]*)\]\(([^)]+)\)\s*$/, line) do
      [_, alt, path] -> {:image, alt, path}
      _ -> nil
    end
  end

  defp take_code(fence_line, rest) do
    lang = fence_line |> String.replace(~r/^\s*```/, "") |> String.trim()
    {code_lines, rest2} = Enum.split_while(rest, fn l -> not fence?(l) end)
    rest3 = Enum.drop(rest2, 1)
    {{:code, lang, Enum.join(code_lines, "\n")}, rest3}
  end

  defp quote?(line), do: Regex.match?(~r/^\s*>/, line)

  defp take_quote(lines) do
    {q, rest} = Enum.split_while(lines, &quote?/1)

    inner =
      q
      |> Enum.map(&Regex.replace(~r/^\s*>\s?/, &1, ""))

    {{:quote, inner}, rest}
  end

  defp list_item(line) do
    cond do
      m = Regex.run(~r/^(\s*)[-*+]\s+(.*)$/, line) ->
        [_, indent, text] = m
        {:ul, indent_level(indent), text}

      m = Regex.run(~r/^(\s*)\d+[.)]\s+(.*)$/, line) ->
        [_, indent, text] = m
        {:ol, indent_level(indent), text}

      true ->
        nil
    end
  end

  defp indent_level(indent), do: div(String.length(indent), 2)

  defp take_list(lines) do
    {items, rest} = Enum.split_while(lines, fn l -> list_item(l) != nil or blank_in_list?(l) end)

    items = Enum.reject(items, &blank?/1)
    kind = items |> hd() |> list_item() |> elem(0)

    parsed =
      Enum.map(items, fn l ->
        {_kind, lvl, text} = list_item(l)
        {lvl, parse_inline(text)}
      end)

    {{:list, kind, parsed}, rest}
  end

  defp blank_in_list?(_), do: false

  defp table_start?(line, rest) do
    String.contains?(line, "|") and
      case rest do
        [sep | _] ->
          Regex.match?(~r/^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/, sep) and String.contains?(sep, "-")

        _ ->
          false
      end
  end

  defp take_table([header | [_sep | rest]]) do
    {rows, rest2} = Enum.split_while(rest, fn l -> String.contains?(l, "|") and not blank?(l) end)
    headers = split_row(header)
    data = Enum.map(rows, &split_row/1)
    {{:table, headers, data}, rest2}
  end

  defp split_row(line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(fn cell -> cell |> String.trim() |> parse_inline() end)
  end

  defp take_paragraph(lines) do
    {para, rest} =
      Enum.split_while(lines, fn l ->
        not blank?(l) and not fence?(l) and match_heading(l) == nil and
          not hr?(l) and not quote?(l) and list_item(l) == nil and
          not pause?(l) and match_image(l) == nil
      end)

    text = para |> Enum.map(&String.trim/1) |> Enum.join(" ")
    {{:paragraph, parse_inline(text)}, rest}
  end

  # ── inline parsing ──────────────────────────────────────────────────────────
  @doc false
  def parse_inline(text), do: scan_inline(text, [])

  defp scan_inline("", acc), do: Enum.reverse(acc)

  defp scan_inline(text, acc) do
    case earliest_marker(text) do
      nil ->
        Enum.reverse([{:text, text} | acc])

      {pos, len, builder, find_close} ->
        before = binary_part(text, 0, pos)
        after_open = binary_part(text, pos + len, byte_size(text) - pos - len)

        case find_close.(after_open) do
          {inner, rest} ->
            acc = if before == "", do: acc, else: [{:text, before} | acc]
            scan_inline(rest, [builder.(inner) | acc])

          :nomatch ->
            # treat the marker as literal text and continue past it
            scan_inline(after_open, [{:text, before <> binary_part(text, pos, len)} | acc])
        end
    end
  end

  # Find the earliest inline marker; return {pos, open_len, builder, closer}.
  defp earliest_marker(text) do
    [
      {"`", 1, &{:code, &1}, closer("`")},
      {"**", 2, &{:strong, parse_inline(&1)}, closer("**")},
      {"__", 2, &{:strong, parse_inline(&1)}, closer("__")},
      {"*", 1, &{:em, parse_inline(&1)}, closer("*")},
      {"_", 1, &{:em, parse_inline(&1)}, closer("_")},
      {"[", 1, & &1, &link_closer/1}
    ]
    |> Enum.map(fn {open, len, builder, closer} ->
      case :binary.match(text, open) do
        {pos, _} -> {pos, len, builder, closer}
        :nomatch -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      found -> Enum.min_by(found, fn {pos, len, _, _} -> {pos, -len} end)
    end
  end

  defp closer(marker) do
    fn rest ->
      case :binary.match(rest, marker) do
        {pos, _} ->
          inner = binary_part(rest, 0, pos)

          tail =
            binary_part(rest, pos + byte_size(marker), byte_size(rest) - pos - byte_size(marker))

          {inner, tail}

        :nomatch ->
          :nomatch
      end
    end
  end

  defp link_closer(rest) do
    case Regex.run(~r/^([^\]]*)\]\(([^)]+)\)/, rest, return: :index) do
      [{0, full}, {ts, tl}, {us, ul}] ->
        label = binary_part(rest, ts, tl)
        url = binary_part(rest, us, ul)
        tail = binary_part(rest, full, byte_size(rest) - full)
        {{:link, label, url}, tail}

      _ ->
        :nomatch
    end
  end
end
