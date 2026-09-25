defmodule PresentexTest do
  use ExUnit.Case

  alias Presentex.{Parser, Renderer, Theme, Style}
  alias Presentex.Image.PNG
  alias Presentex.Input.Evdev

  @priv Path.join([__DIR__, "..", "priv"])
  @sample File.read!(Path.join(@priv, "sample.md"))

  describe "parser" do
    test "extracts front matter and splits slides" do
      deck = Parser.parse(@sample)
      assert deck.meta["title"] == "Presentations on the BEAM"
      assert deck.meta["author"] == "Marc"
      assert length(deck.slides) == 6
    end

    test "detects center flag and pauses" do
      deck = Parser.parse(@sample)
      assert Enum.at(deck.slides, 0).center?
      assert Enum.at(deck.slides, 2).pause_count == 2
    end

    test "parses headings, lists, code, quotes, tables, images" do
      deck = Parser.parse(@sample)
      kinds = fn slide -> Enum.map(slide.blocks, &elem_kind/1) end

      assert :heading in kinds.(Enum.at(deck.slides, 1))
      assert :list in kinds.(Enum.at(deck.slides, 1))
      assert :quote in kinds.(Enum.at(deck.slides, 1))
      assert :code in kinds.(Enum.at(deck.slides, 2))
      assert :table in kinds.(Enum.at(deck.slides, 3))
      assert :image in kinds.(Enum.at(deck.slides, 4))
    end

    test "inline parsing handles emphasis, code, links" do
      assert Parser.parse_inline("plain **bold** and *em* and `code`") == [
               {:text, "plain "},
               {:strong, [text: "bold"]},
               {:text, " and "},
               {:em, [text: "em"]},
               {:text, " and "},
               {:code, "code"}
             ]

      assert [{:text, "see "}, {:link, "repo", "https://x.y"}] =
               Parser.parse_inline("see [repo](https://x.y)")
    end
  end

  describe "renderer" do
    setup do
      %{theme: Theme.get(:default)}
    end

    test "wraps text to width and never exceeds it", %{theme: theme} do
      slide = Parser.parse(@sample) |> Map.get(:slides) |> Enum.at(1)

      for line <- Renderer.render(slide, theme, 40) do
        assert Style.visible_width(line) <= 40
      end
    end

    test "pauses gate later blocks", %{theme: theme} do
      slide = Parser.parse(@sample) |> Map.get(:slides) |> Enum.at(2)

      step0 = Renderer.render(slide, theme, 60, 0) |> flatten_text()
      step2 = Renderer.render(slide, theme, 60, 2) |> flatten_text()

      refute step0 =~ "zero NIFs"
      assert step2 =~ "zero NIFs"
    end

    test "image block renders as half-block runs when resolvable", %{theme: theme} do
      slide = Parser.parse(@sample) |> Map.get(:slides) |> Enum.at(4)
      lines = Renderer.render(slide, theme, 30, 9999, base_dir: @priv, max_image_rows: 6)

      # the image contributes runs whose glyph is the upper half block
      assert Enum.any?(lines, fn line ->
               Enum.any?(line, fn {t, st} -> t == "▀" and Map.has_key?(st, :fg) end)
             end)
    end

    test "missing image falls back to a placeholder", %{theme: _theme} do
      lines = Presentex.render_slide("![x](nope.png)", 0, width: 40, base_dir: @priv)
      assert flatten_text(lines) =~ "[image:"
    end
  end

  describe "PNG decoder" do
    test "decodes a known 4x4 RGB image to exact pixels" do
      {:ok, img} = PNG.decode_file(Path.join(@priv, "test4.png"))
      assert {img.width, img.height} == {4, 4}
      assert byte_size(img.pixels) == 4 * 4 * 3
      assert pixel(img, 0, 0) == {255, 0, 0}
      assert pixel(img, 3, 0) == {255, 255, 255}
      assert pixel(img, 0, 3) == {0, 0, 0}
    end

    test "rejects non-PNG data" do
      assert {:error, :not_a_png} = PNG.decode(<<0, 1, 2, 3>>)
    end
  end

  describe "evdev input" do
    test "decodes big-endian and little-endian records" do
      be = <<0::64, 3::big-16, 17::big-16, -1::big-signed-32>>
      assert Evdev.decode(be, :big) == {3, 17, -1}

      le = <<0::128, 1::little-16, 0x130::little-16, 1::little-signed-32>>
      assert Evdev.decode(le, :little) == {1, 0x130, 1}
    end

    test "maps D-pad axes and buttons; ignores releases" do
      b = Evdev.layout(:be32).buttons
      assert Evdev.map_event({3, 17, -1}, b) == :up
      assert Evdev.map_event({3, 17, 1}, b) == :down
      assert Evdev.map_event({3, 16, -1}, b) == :left
      assert Evdev.map_event({3, 16, 1}, b) == :right
      assert Evdev.map_event({1, 0x130, 1}, b) == :space
      assert Evdev.map_event({1, 0x130, 0}, b) == :ignore
      assert Evdev.map_event({1, 0x13C, 1}, b) == :quit
    end

    test "reader skips releases and returns the next navigation key" do
      layout = Evdev.layout(:be32)
      ev = fn t, c, v -> <<0::64, t::big-16, c::big-16, v::big-signed-32>> end
      path = Path.join(System.tmp_dir!(), "presentex_ev_#{System.unique_integer([:positive])}")
      File.write!(path, ev.(1, 0x130, 0) <> ev.(3, 17, 1))

      {:ok, fd} = Evdev.open(path)
      assert Evdev.read_key(fd, layout) == :down
      Evdev.close(fd)
      File.rm(path)
    end
  end

  describe "presenter loop (fake terminal)" do
    test "navigates through slides and quits cleanly" do
      {:ok, agent} =
        Agent.start_link(fn -> %{keys: [:right, :space, :end, :left, :quit], frames: 0} end)

      defmodule FakeTerm do
        @behaviour Presentex.Terminal
        def setup(opts), do: Keyword.fetch!(opts, :agent)
        def teardown(_), do: :ok

        def draw(agent, %Presentex.Frame{}),
          do: Agent.update(agent, &%{&1 | frames: &1.frames + 1})

        def read_key(agent) do
          Agent.get_and_update(agent, fn
            %{keys: [k | rest]} = s -> {k, %{s | keys: rest}}
            s -> {:quit, s}
          end)
        end
      end

      assert :ok =
               Presentex.run(Path.join(@priv, "sample.md"),
                 terminal: FakeTerm,
                 terminal_opts: [agent: agent]
               )

      assert Agent.get(agent, & &1.frames) >= 5
    end
  end

  describe "bitmap font + canvas" do
    test "built-in font carries the expected 'A' glyph and pixel order" do
      font = Presentex.Font.Builtin.font()
      assert {font.width, font.height} == {8, 8}
      assert Presentex.Font.rows(font, ?A) == [12, 30, 51, 51, 63, 51, 51, 0]
      # row 12 = 0b00001100, LSB = leftmost: columns 2 and 3 set
      assert Presentex.Font.pixel?(font, 12, 2)
      refute Presentex.Font.pixel?(font, 12, 0)
    end

    test "canvas rasterizes a glyph with fg/bg" do
      font = %Presentex.Font{
        width: 2,
        height: 2,
        glyphs: %{?X => <<0b01, 0b10>>},
        bit_order: :lsb_left
      }

      cell = {?X, {255, 0, 0}, {0, 0, 0}}

      rgb =
        Presentex.Canvas.new(2, 2, {0, 0, 0})
        |> Presentex.Canvas.draw_grid([[cell]], font, 1, 0, 0)
        |> Presentex.Canvas.to_rgb()

      assert binary_part(rgb, 0, 3) == <<255, 0, 0>>
      assert binary_part(rgb, 9, 3) == <<255, 0, 0>>
      assert binary_part(rgb, 3, 3) == <<0, 0, 0>>
    end

    test "PSF2 parses into a font" do
      header =
        <<0x72, 0xB5, 0x4A, 0x86, 0::little-32, 32::little-32, 0::little-32, 1::little-32,
          8::little-32, 8::little-32, 8::little-32>>

      glyph = <<0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00>>
      {:ok, font} = Presentex.Font.PSF.parse(header <> glyph)
      assert {font.width, font.height, font.bit_order} == {8, 8, :msb_left}
      assert Presentex.Font.has?(font, 0)
      assert Presentex.Font.pixel?(font, 0xFF, 3)
    end
  end

  describe "pixel slide renderer" do
    test "renders a slide to a full RGB buffer with image content" do
      slide = Parser.parse(@sample) |> Map.get(:slides) |> Enum.at(4)
      font = Presentex.Font.Builtin.font()

      {rgb, w, h} =
        Presentex.Pixel.render(slide, Theme.get(:default),
          font: font,
          width_px: 320,
          height_px: 240,
          scale: 1,
          base_dir: @priv,
          index: 4,
          total: 6,
          title: "t"
        )

      assert {w, h} == {320, 240}
      assert byte_size(rgb) == 320 * 240 * 3
      assert rgb |> :binary.bin_to_list() |> Enum.uniq() |> length() > 3
    end
  end

  describe "framebuffer" do
    test "pack_frame pads rows to the stride" do
      buf = Presentex.Framebuffer.pack_frame(<<255, 0, 0>>, 1, 1, :rgb565, 4)
      assert buf == <<0x00, 0xF8, 0, 0>>
    end

    test "packs RGB565 and XRGB8888 correctly" do
      rgb = <<255, 0, 0, 0, 255, 0>>
      assert Presentex.Framebuffer.encode(rgb, 2, :xrgb8888) == <<0, 0, 255, 0, 0, 255, 0, 0>>
      # red -> 0xF800, green -> 0x07E0, little-endian
      assert Presentex.Framebuffer.encode(rgb, 2, :rgb565) == <<0x00, 0xF8, 0xE0, 0x07>>
    end

    test "blits a PNG to a fake framebuffer device at the right offset" do
      path = Path.join(System.tmp_dir!(), "presentex_fb_#{System.unique_integer([:positive])}")
      line_bytes = 64

      assert :ok =
               Presentex.Framebuffer.blit(Path.join(@priv, "test4.png"),
                 device: path,
                 bytes_per_line: line_bytes,
                 format: :rgb565,
                 x: 1,
                 y: 2,
                 max_w: 4,
                 max_h: 4
               )

      data = File.read!(path)
      # first pixel (255,0,0) -> 0xF800 little-endian at offset y*line + x*2
      offset = 2 * line_bytes + 1 * 2
      assert binary_part(data, offset, 2) == <<0x00, 0xF8>>
      File.rm(path)
    end
  end

  defp elem_kind(:hr), do: :hr
  defp elem_kind(:pause), do: :pause
  defp elem_kind(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  defp pixel(%{pixels: px, width: w}, x, y) do
    off = (y * w + x) * 3
    <<_::binary-size(off), r, g, b, _::binary>> = px
    {r, g, b}
  end

  defp flatten_text(lines) do
    Enum.map_join(lines, "\n", fn line -> Enum.map_join(line, "", fn {t, _} -> t end) end)
  end
end
