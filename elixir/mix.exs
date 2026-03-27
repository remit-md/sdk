defmodule RemitMd.MixProject do
  use Mix.Project

  def project do
    [
      app: :remit,
      version: "0.1.8",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "remit.md SDK for Elixir — universal payment protocol for AI agents",
      package: package(),
      source_url: "https://github.com/remit-md/sdk",
      docs: [main: "RemitMd", extras: ["README.md"]],
      # Coverage gate: target 50% (MASTER.md); initial gate 35% (compliance skipped w/o server).
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {RemitMd.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/remit-md/sdk"},
      files: ~w(lib mix.exs README.md LICENSE),
      maintainers: ["remit.md"]
    ]
  end
end
