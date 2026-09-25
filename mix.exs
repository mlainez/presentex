defmodule Presentex.MixProject do
  use Mix.Project

  def project do
    [
      app: :presentex,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Presentex.CLI, name: "presentex"],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # No hex dependencies: the whole tool is pure Elixir and compiles to portable
  # BEAM bytecode, so it runs on any target the BEAM runs on (including Nerves on
  # embedded ARM/PowerPC boards) with no native build step.
  #
  # Optional, for richer syntax highlighting later (also pure Elixir):
  #   {:makeup, "~> 1.1"},
  #   {:makeup_elixir, "~> 0.16"},
  #   {:makeup_c, "~> 0.1"},
  # then map makeup token atoms to the :syn_* roles inside Presentex.Highlighter.
  defp deps, do: []
end
