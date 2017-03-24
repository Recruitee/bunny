defmodule Bunny do
  def start_link(opts) do
    import Supervisor.Spec, warn: false

    worker_modules = opts[:workers] || []

    infra = [
      worker(Bunny.Connection, [])
    ]
    workers = Enum.map(worker_modules, &worker(&1, []))

    opts = [strategy: :one_for_one, name: Bunny.Supervisor]
    Supervisor.start_link(infra ++ workers, opts)
  end

  def stop do
    Supervisor.stop(Bunny.Supervisor)
  end

  def server_url do
    Application.get_env(:bunny, :server_url, "amqp://localhost")
  end
end
