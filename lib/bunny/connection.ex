defmodule Bunny.Connection do
  use GenServer
  require Logger

  @reconnect_delay 1000

  @amqp_connection Twin.get(AMQP.Connection)
  @worker Twin.get(Bunny.Worker)

  ## CLIENT API

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ## CALLBACKS

  def init(_modules) do
    send self(), :connect
    {:ok, nil}
  end

  def handle_info(:connect, state) do
    handle_connect(@amqp_connection.open(Bunny.server_url), state)
  end

  def handle_connect({:ok, conn}, _state) do
    Logger.info "Connected to RabbitMQ at #{Bunny.server_url}"

    # link with AMQP connection process
    Process.link(conn.pid)

    # TODO: Start multiple workers
    {:ok, worker} = @worker.start_link(conn, mod: Bunny.Debug, queue: "bunny.debug")

    {:noreply, %{conn: conn, workers: [worker]}}
  end

  def handle_connect({:error, reason}, %{workers: workers}) do
    Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    # stop all workers
    for pid <- workers, do: @worker.stop(pid)
    # try to reconnect
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, nil}
  end

  def handle_connect({:error, reason}, _state) do
    Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    # try to reconnect
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, nil}
  end
end
