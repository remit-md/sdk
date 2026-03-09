defmodule RemitMd.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Start :inets and :ssl for :httpc (may already be started)
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end

    case :ssl.start() do
      :ok -> :ok
      {:error, {:already_started, :ssl}} -> :ok
    end

    children = []
    opts = [strategy: :one_for_one, name: RemitMd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
