defmodule RemitMd.MixProject do
  use Mix.Project

  def project do
    [
      app: :remitmd,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "remit.md SDK for Elixir — universal payment protocol for AI agents",
      package: package(),
      source_url: "https://github.com/remit-md/sdk",
      docs: [main: "RemitMd", extras: ["README.md"]]
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
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/remit-md/sdk"}
    ]
  end
end
