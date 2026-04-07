defmodule RemitMd.MixProject do
  use Mix.Project

  def project do
    [
      app: :remit,
      version: "0.4.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "DEPRECATED: Use pay-cli or pay SDKs instead. See https://pay-skill.com/docs",
      package: package(),
      source_url: "https://github.com/remit-md/pay-sdk",
      docs: [main: "RemitMd", extras: ["README.md"]],
      # Coverage gate: target 50%, gate 35%.
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
      links: %{"GitHub" => "https://github.com/remit-md/pay-sdk"},
      files: ~w(lib mix.exs README.md LICENSE),
      maintainers: ["remit.md"]
    ]
  end
end
