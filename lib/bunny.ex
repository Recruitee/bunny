defmodule Bunny do
  import Supervisor.Spec, warn: false

  defmodule WorkersSupervisor do
    def start_link(opts) do
      modules = opts[:workers] || []
      children = Enum.map(modules, &worker(&1, []))

      opts = [strategy: :one_for_one, name: __MODULE__]
      Supervisor.start_link(children, opts)
    end
  end


  def start_link(opts) do
    children = [
      worker(Bunny.Connection, []),
      supervisor(Bunny.WorkersSupervisor, [opts])
    ]

    opts = [strategy: :rest_for_one, name: Bunny.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def stop do
    Supervisor.stop(Bunny.Supervisor)
  end

  def server_url do
    Application.get_env(:bunny, :server_url, "amqp://localhost")
  end
end
