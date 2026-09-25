defmodule Presentex.Terminal.Console do
  @moduledoc """
  Shared console plumbing: alternate-screen control, size query, an ANSI frame
  renderer (used by the text backends), and a raw-stdin key reader.
  """

  alias Presentex.{Renderer, Style, Theme, Frame}

  # ── screen control ──────────────────────────────────────────────────────────
  def enter do
    write([IO.ANSI.clear(), "\e[?1049h", "\e[?25l"])
  end

  def leave do
    write(["\e[?25h", "\e[?1049l"])
  end

  def write(iodata) do
    IO.binwrite(iodata)
    :ok
  end

  def size do
    {dimension(:columns, 80), dimension(:rows, 24)}
  end

  defp dimension(which, fallback) do
    case apply(:io, which, []) do
      {:ok, n} when is_integer(n) and n > 0 -> n
      _ -> fallback
    end
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  # ── ANSI frame composition ──────────────────────────────────────────────────
  @doc "Render a `%Frame{}` to ANSI iodata for an interactive console."
  def render_frame(%Frame{} = frame) do
    {cols, rows} = size()
    content_w = max(cols - 2 * frame.margin, 10)
    body_rows = max(rows - 2, 1)

    lines =
      Renderer.render(frame.slide, frame.theme, content_w, frame.reveal,
        base_dir: frame.base_dir,
        max_image_rows: max(body_rows - 1, 4)
      )

    lines = if frame.slide.center?, do: Enum.map(lines, &center_line(&1, content_w)), else: lines
    top = vertical_pad(length(lines), body_rows, frame.slide.center?)

    [
      IO.ANSI.home(),
      IO.ANSI.clear(),
      blank_lines(top),
      Enum.map(lines, fn line -> [margin(frame.margin), Style.render_line(line), "\r\n"] end),
      footer(frame, cols, rows)
    ]
  end

  defp vertical_pad(_n, _rows, false), do: 0
  defp vertical_pad(n, rows, true), do: max(div(rows - n, 2), 0)

  defp center_line(line, width) do
    pad = max(div(width - Style.visible_width(line), 2), 0)
    [{String.duplicate(" ", pad), %{}} | line]
  end

  defp margin(n), do: String.duplicate(" ", n)
  defp blank_lines(0), do: []
  defp blank_lines(n), do: String.duplicate("\r\n", n)

  defp footer(frame, cols, rows) do
    num = frame.index + 1
    right = "#{num} / #{frame.total}"
    bar_width = max(cols - 2 * frame.margin, 1)
    progress = progress_bar(num, frame.total, min(bar_width, 24))

    gap =
      max(
        bar_width - String.length(frame.title) - String.length(right) - String.length(progress) -
          2,
        1
      )

    runs = [
      {frame.title, Theme.role(frame.theme, :footer)},
      {String.duplicate(" ", gap), %{}},
      {progress <> " ", Theme.role(frame.theme, :footer_progress)},
      {right, Theme.role(frame.theme, :footer)}
    ]

    [IO.ANSI.cursor(rows, frame.margin + 1), Style.render_line(runs)]
  end

  defp progress_bar(num, total, width) when total > 0 do
    filled = round(num / total * width)
    String.duplicate("█", filled) <> String.duplicate("░", max(width - filled, 0))
  end

  defp progress_bar(_, _, _), do: ""

  # ── raw stdin key reader ────────────────────────────────────────────────────
  def read_stdin_key do
    case IO.getn(:stdio, "", 1) do
      :eof -> :eof
      {:error, _} -> :eof
      "\e" -> read_escape()
      other -> classify(other)
    end
  end

  defp read_escape do
    case IO.getn(:stdio, "", 1) do
      "[" -> read_csi()
      "O" -> read_csi()
      _ -> :unknown
    end
  end

  defp read_csi do
    case IO.getn(:stdio, "", 1) do
      "A" -> :up
      "B" -> :down
      "C" -> :right
      "D" -> :left
      "H" -> :home
      "F" -> :end
      "5" -> swallow_tilde(:up)
      "6" -> swallow_tilde(:down)
      _ -> :unknown
    end
  end

  defp swallow_tilde(key) do
    _ = IO.getn(:stdio, "", 1)
    key
  end

  defp classify(" "), do: :space
  defp classify("\r"), do: :enter
  defp classify("\n"), do: :enter
  defp classify(<<127>>), do: :backspace
  defp classify(<<8>>), do: :backspace
  defp classify("q"), do: :quit
  defp classify(<<3>>), do: :quit
  defp classify(char), do: {:char, char}
end
