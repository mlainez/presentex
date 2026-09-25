defmodule Presentex.Frame do
  @moduledoc """
  A snapshot of what to draw, handed by the run loop to a terminal backend. The
  backend decides *how* to render it — ANSI text for a console, or pixels for a
  framebuffer — so the loop stays output-agnostic.
  """

  alias Presentex.Parser.Slide

  @type t :: %__MODULE__{
          slide: Slide.t(),
          theme: map(),
          index: non_neg_integer(),
          total: pos_integer(),
          title: binary(),
          reveal: non_neg_integer(),
          base_dir: binary(),
          margin: non_neg_integer()
        }

  defstruct slide: nil,
            theme: %{},
            index: 0,
            total: 1,
            title: "",
            reveal: 0,
            base_dir: ".",
            margin: 2
end
