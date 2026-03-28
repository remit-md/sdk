defmodule AcceptanceFlows.MixProject do
  use Mix.Project

  def project do
    [
      app: :acceptance_flows,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:remit, path: "../../elixir"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end
end
