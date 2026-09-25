defmodule Presentex.CLI do
  @moduledoc """
  Command-line entry point. Build with `mix escript.build`, then:

      ./presentex talk.md
      ./presentex --evdev --device /dev/input/event0 talk.md
      ./presentex --framebuffer --scale 2 --font priv/fonts/spleen-16x32.psfu talk.md
      ./presentex --export out/ talk.md     # render slides to PNGs, no hardware
  """

  alias Presentex.Font

  def main(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv,
        switches: [
          theme: :string,
          margin: :integer,
          evdev: :boolean,
          framebuffer: :boolean,
          device: :string,
          layout: :string,
          font: :string,
          scale: :integer,
          width: :integer,
          height: :integer,
          export: :string,
          help: :boolean
        ],
        aliases: [
          t: :theme,
          m: :margin,
          e: :evdev,
          f: :framebuffer,
          d: :device,
          l: :layout,
          h: :help
        ]
      )

    cond do
      opts[:help] or rest == [] -> usage()
      opts[:export] -> export(hd(rest), opts)
      true -> Presentex.run(hd(rest), run_opts(opts))
    end
  end

  defp export(file, opts) do
    dir = opts[:export]
    File.mkdir_p!(dir)
    deck = Presentex.parse(File.read!(file))
    font = load_font(opts)

    common =
      [width_px: opts[:width] || 1280, height_px: opts[:height] || 720, scale: opts[:scale] || 3]
      |> put_if(:font, font)
      |> put_if(:theme, opts[:theme] && String.to_atom(opts[:theme]))

    for i <- 0..(length(deck.slides) - 1) do
      out = Path.join(dir, "slide_#{String.pad_leading("#{i}", 2, "0")}.png")
      Presentex.export_png(file, i, out, common)
      IO.puts(out)
    end
  end

  defp run_opts(opts) do
    []
    |> put_if(:theme, opts[:theme] && String.to_atom(opts[:theme]))
    |> put_if(:margin, opts[:margin])
    |> backend(opts)
  end

  defp backend(run_opts, opts) do
    cond do
      opts[:framebuffer] ->
        terminal_opts =
          []
          |> put_if(:device, opts[:device])
          |> put_if(:scale, opts[:scale])
          |> put_if(:width_px, opts[:width])
          |> put_if(:height_px, opts[:height])
          |> put_if(:font, load_font(opts))
          |> framebuffer_input(opts)

        run_opts
        |> Keyword.put(:terminal, Presentex.Terminal.Framebuffer)
        |> Keyword.put(:terminal_opts, terminal_opts)

      opts[:evdev] ->
        terminal_opts =
          [] |> put_if(:device, opts[:device]) |> put_if(:layout, atom(opts[:layout]))

        run_opts
        |> Keyword.put(:terminal, Presentex.Terminal.Evdev)
        |> Keyword.put(:terminal_opts, terminal_opts)

      true ->
        run_opts
    end
  end

  defp framebuffer_input(terminal_opts, opts) do
    if opts[:evdev] do
      terminal_opts
      |> Keyword.put(:input, :evdev)
      |> put_if(:input_device, opts[:device])
      |> put_if(:layout, atom(opts[:layout]))
    else
      terminal_opts
    end
  end

  defp load_font(opts) do
    case opts[:font] do
      nil ->
        nil

      path ->
        case Font.PSF.load(path) do
          {:ok, font} -> font
          {:error, reason} -> raise "could not load font #{path}: #{inspect(reason)}"
        end
    end
  end

  defp atom(nil), do: nil
  defp atom(s), do: String.to_atom(s)

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, val), do: Keyword.put(opts, key, val)

  defp usage do
    IO.puts("""
    presentex - terminal & framebuffer markdown presentations on the BEAM

      presentex [options] FILE.md

    Output:
      -t, --theme NAME      color theme (default: default)
      -m, --margin N        margin in columns (default: 2)
      -f, --framebuffer     render pixels to a framebuffer device (HDMI)
          --scale N         font magnification for --framebuffer (default: 2)
          --font PATH       PSF font file for --framebuffer (default: built-in 8x8)
          --width / --height  framebuffer size in px (default: 1280x720)
          --export DIR      render each slide to a PNG in DIR (no hardware)

    Input:
      -e, --evdev           read navigation from a Linux input device
      -d, --device PATH     input/framebuffer device path
      -l, --layout NAME     evdev layout: le64 | le32 | be64 | be32 (default: le64)

      -h, --help            show this help

    Keys (keyboard / controller):
      ->/Space/Enter, A/+   next (reveals pauses first)
      <-/p/k, B/-           previous
      g/Home  G/End         first / last slide
      q, Home button        quit
    """)
  end
end
