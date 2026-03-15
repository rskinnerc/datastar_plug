defmodule DatastarPlug.MixProject do
  use Mix.Project

  @version "0.2.3"
  @source_url "https://github.com/rskinnerc/datastar_plug"

  def project do
    [
      app: :datastar_plug,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Hex publishing
      package: package(),
      # ExDoc
      name: "DatastarPlug",
      description: "Stateless SSE helpers for Datastar integration in any Plug/Phoenix app.",
      docs: docs(),
      # Dialyxir
      dialyzer: [
        plt_add_apps: [:plug, :jason],
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def cli do
    [preferred_envs: ["test.ci": :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Runtime dependencies
      {:plug, "~> 1.14"},
      {:jason, "~> 1.0"},
      # Dev / test only — never leak into consumer applications
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Datastar" => "https://data-star.dev",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Ronald Skinner"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r/README/,
        Changelog: ~r/CHANGELOG/,
        License: ~r/LICENSE/
      ],
      groups_for_docs: [
        "Connection Lifecycle": &(&1[:name] in [:init_sse, :close_sse]),
        "Patching the DOM": &(&1[:name] in [:patch_fragment, :remove_fragment, :execute_script]),
        Signals: &(&1[:name] in [:patch_signals]),
        Utilities: &(&1[:name] in [:redirect_to, :parse_signals])
      ],
      api_reference: false
    ]
  end
end
