defmodule Bunny.Connection do
  use GenServer
  require Logger

  @reconnect_delay 1000

  @amqp_connection Twin.get(AMQP.Connection)
  @worker Twin.get(Bunny.Worker)

  ## CLIENT API

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end


  ## CALLBACKS

  def init(args) do
    send self(), :connect
    opts =
      %{
        enable_logger: true
      }
      |> Map.merge(Map.new(args))
    {:ok, opts}
  end

  def handle_info(:connect, state) do
    handle_connect(@amqp_connection.open(Bunny.server_url), state)
  end

  def handle_connect({:ok, conn}, %{specs: specs, enable_logger: enable_logger}) do
    if enable_logger do
      Logger.info "Connected to RabbitMQ at #{Bunny.server_url}"
    end

    # link with AMQP connection process
    Process.link(conn.pid)

    workers = for spec <- specs do
      {:ok, worker} = @worker.start_link(conn, spec ++ [enable_logger: enable_logger])
      worker
    end

    {:noreply, %{conn: conn, workers: workers, specs: specs, enable_logger: enable_logger}}
  end

  def handle_connect({:error, reason}, %{workers: workers, specs: specs, enable_logger: enable_logger}) do
    if enable_logger do
      Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    end

    # stop all workers
    for pid <- workers, do: @worker.stop(pid)

    # try to reconnect
    Process.send_after(self(), :connect, @reconnect_delay)

    {:noreply, %{specs: specs, enable_logger: enable_logger}}
  end

  def handle_connect({:error, reason}, %{enable_logger: enable_logger} = state) do
    if enable_logger do
      Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}"
    end

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
