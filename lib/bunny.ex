defmodule Bunny do
  import Supervisor.Spec, warn: false

  def start(_type, _args) do
    children = [
      worker(Bunny.Connection, [])
    ]

    opts = [strategy: :one_for_one, name: Bunny.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def server_url do
    Application.get_env(:bunny, :server_url, "amqp://localhost")
  end

  ## UTILS

  def header(%{headers: :undefined}, _), do: nil
  def header(%{headers: headers}, key) do
    Enum.find_value headers, fn
      {^key, _, value}  -> value
      _                 -> nil
    end
  end
end
