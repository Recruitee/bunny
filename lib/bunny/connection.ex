defmodule Bunny.Connection do
  use GenServer
  require Logger

  @reconnect_delay 500
  @max_retries 10

  ## CLIENT API

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  ## CALLBACKS

  def init(_) do
    case connect() do
      {:ok, conn} ->
        {:ok, conn}
      {:error, _} ->
        {:ok, nil}
    end
  end

  def handle_call(:get, _, nil),  do: {:reply, {:error, :disconnected}, nil}
  def handle_call(:get, _, conn), do: {:reply, {:ok, conn}, conn}

  def handle_info({:connect, retry}, _) do
    case connect(retry) do
      {:ok, conn} ->
        {:noreply, conn}
      {:error, _reason} ->
        {:noreply, nil}
    end
  end

  def handle_info({:DOWN, _, :process, _pid, _reason}, _) do
    Logger.warn "#{inspect self()} Disconnected, reconnecting"
    send self(), {:connect, 0}
    {:noreply, nil}
  end

  defp connect(retry \\ 0) do
    case AMQP.Connection.open(Bunny.server_url) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        Logger.info "Connected to RabbitMQ at #{Bunny.server_url}"
        {:ok, conn}
      {:error, reason} ->
        delay = retry * @reconnect_delay
        Logger.warn "Error connecting to RabbitMQ: #{inspect(reason)}. Will try again in #{delay}"
        Process.send_after(self(), {:connect, retry + 1}, delay)
        {:error, reason}
    end
  end
end
