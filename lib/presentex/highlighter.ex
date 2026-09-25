defmodule Presentex.Highlighter do
  @moduledoc """
  Pure-Elixir, dependency-free syntax highlighting — the direct answer to the
  Oniguruma/syntect problem. Instead of a C regex engine, this is a small
  hand-written tokenizer with per-language keyword sets. It is deliberately
  approximate (line-oriented, not a full grammar) but needs no NIFs and runs on
  any BEAM target.

  Want richer highlighting later? `highlight/3` is the only seam: swap in
  `makeup` + `makeup_*` lexers (also pure Elixir) and map their token atoms to
  the `:syn_*` theme roles. The rest of the renderer never changes.

  Returns a list of lines, each a list of `{text, style}` runs.
  """

  alias Presentex.Theme

  @keywords %{
    "elixir" => ~w(def defp defmodule defmacro do end fn if else unless case cond when with for
         import alias require use receive try rescue after raise throw catch nil true
         false and or not in __MODULE__ @moduledoc @doc @spec),
    "rust" => ~w(fn let mut const struct enum impl trait pub use mod match if else loop while for
         in return self Self where async await move ref dyn unsafe as crate super true false),
    "c" => ~w(int char void short long float double struct union enum static const return if else
         for while do switch case break continue sizeof typedef unsigned signed extern),
    "python" =>
      ~w(def class return if elif else for while in import from as try except finally with
         lambda yield None True False and or not is pass break continue global),
    "javascript" =>
      ~w(function const let var return if else for while do switch case break continue new
         class extends import export from async await null undefined true false typeof),
    "bash" =>
      ~w(if then else elif fi for while do done case esac function in return export local),
    "erlang" => ~w(case of end fun receive after if when begin try catch module export)
  }

  @doc "Highlight `code` for `lang` using `theme`, returning lines of runs."
  @spec highlight(binary(), binary(), map()) :: [[{binary(), map()}]]
  def highlight(code, lang, theme) do
    lang = normalize(lang)
    keywords = Map.get(@keywords, lang)

    code
    |> String.split("\n")
    |> Enum.map(fn line -> highlight_line(line, lang, keywords, theme) end)
  end

  defp normalize(lang) do
    case String.downcase(String.trim(lang || "")) do
      "ex" -> "elixir"
      "exs" -> "elixir"
      "rs" -> "rust"
      "py" -> "python"
      "js" -> "javascript"
      "sh" -> "bash"
      "shell" -> "bash"
      "erl" -> "erlang"
      other -> other
    end
  end

  # No keyword set for this language: dim every line uniformly.
  defp highlight_line(line, _lang, nil, theme) do
    [{line, Theme.role(theme, :code_default)}]
  end

  defp highlight_line(line, lang, keywords, theme) do
    case split_comment(line, lang) do
      {code, nil} ->
        tokenize(code, keywords, theme)

      {code, comment} ->
        tokenize(code, keywords, theme) ++ [{comment, Theme.role(theme, :syn_comment)}]
    end
  end

  defp split_comment(line, lang) do
    marker = if lang in ["c", "rust", "javascript"], do: "//", else: "#"

    case :binary.match(line, marker) do
      {pos, _} ->
        # crude: ignore markers that sit inside a string literal
        if inside_string?(line, pos) do
          {line, nil}
        else
          {binary_part(line, 0, pos), binary_part(line, pos, byte_size(line) - pos)}
        end

      :nomatch ->
        {line, nil}
    end
  end

  defp inside_string?(line, pos) do
    prefix = binary_part(line, 0, pos)
    rem(count_occurrences(prefix, "\""), 2) == 1
  end

  defp count_occurrences(str, ch) do
    str |> String.graphemes() |> Enum.count(&(&1 == ch))
  end

  defp tokenize(code, keywords, theme), do: tokenize(code, keywords, theme, [])

  defp tokenize("", _kw, _theme, acc), do: Enum.reverse(acc)

  defp tokenize(code, kw, theme, acc) do
    {run, rest} = next_token(code, kw, theme)
    tokenize(rest, kw, theme, [run | acc])
  end

  defp next_token(code, keywords, theme) do
    cond do
      m = Regex.run(~r/^"(?:\\.|[^"\\])*"?/, code) ->
        tok = hd(m)
        {{tok, Theme.role(theme, :syn_string)}, rest_after(code, tok)}

      m = Regex.run(~r/^'(?:\\.|[^'\\])*'?/, code) ->
        tok = hd(m)
        {{tok, Theme.role(theme, :syn_string)}, rest_after(code, tok)}

      m = Regex.run(~r/^\d[\d_]*\.?\d*/, code) ->
        tok = hd(m)
        {{tok, Theme.role(theme, :syn_number)}, rest_after(code, tok)}

      m = Regex.run(~r/^[A-Za-z_@][A-Za-z0-9_!?]*/, code) ->
        tok = hd(m)
        rest = rest_after(code, tok)
        {{tok, ident_style(tok, rest, keywords, theme)}, rest}

      m = Regex.run(~r/^\s+/, code) ->
        tok = hd(m)
        {{tok, %{}}, rest_after(code, tok)}

      true ->
        tok = String.first(code)
        {{tok, Theme.role(theme, :syn_punct)}, rest_after(code, tok)}
    end
  end

  defp ident_style(tok, rest, keywords, theme) do
    cond do
      tok in keywords -> Theme.role(theme, :syn_keyword)
      String.starts_with?(rest, "(") -> Theme.role(theme, :syn_func)
      true -> %{}
    end
  end

  defp rest_after(code, tok) do
    len = byte_size(tok)
    binary_part(code, len, byte_size(code) - len)
  end
end
