defmodule Bunny.Connection do
  use GenServer
  require Logger

  @reconnect_delay 1000

  @amqp_connection Twin.get(AMQP.Connection)
  @worker Twin.get(Bunny.Worker)

  ## CLIENT API

  def start_link(specs \\ []) do
    GenServer.start_link(__MODULE__, specs, name: __MODULE__)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end


  ## CALLBACKS

  def init(specs) do
    send self(), :connect
    {:ok, %{specs: specs}}
  end

  def handle_info(:connect, state) do
    handle_connect(@amqp_connection.open(Bunny.server_url), state)
  end

  def handle_connect({:ok, conn}, %{specs: specs}) do
    Logger.info "Connected to RabbitMQ at #{Bunny.server_url}"

    # link with AMQP connection process
    Process.link(conn.pid)

    workers = for spec <- specs do
      {:ok, worker} = @worker.start_link(conn, spec)
      worker
    end

    {:noreply, %{conn: conn, workers: workers, specs: specs}}
  end

  def handle_connect({:error, reason}, %{workers: workers, specs: specs}) do
    Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    # stop all workers
    for pid <- workers, do: @worker.stop(pid)
    # try to reconnect
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, %{specs: specs}}
  end

  def handle_connect({:error, reason}, state) do
    Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    # try to reconnect
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, state}
  end

  def terminate(_reason, %{conn: conn, workers: workers}) do
    # stop all workers
    for pid <- workers, do: @worker.stop(pid)

    # close AMQP connection
    Process.unlink(conn.pid)
    AMQP.Connection.close(conn)
  end
end
