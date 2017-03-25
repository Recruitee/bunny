defmodule Bunny.Connection do
  use GenServer
  require Logger

  @reconnect_time 5_000

  ## CLIENT API

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  ## CALLBACKS

  def init(_), do: {:ok, connect()}

  def handle_call(:get, _, nil),  do: {:reply, {:error, :disconnected}, nil}
  def handle_call(:get, _, conn), do: {:reply, {:ok, conn}, conn}

  def handle_call(:close, _, nil),  do: {:reply, :ok, nil}
  def handle_call(:close, _, conn) do
    AMQP.Connection.close(conn)
    {:reply, :ok, nil}
  end

  def handle_info(:connect, _), do: {:noreply, connect()}
  def handle_info({:DOWN, _, :process, _pid, _reason}, _) do
    Logger.warn "#{inspect self()} Disconnected, reconnecting"
    {:noreply, connect()}
  end

  ## INTERNALS

  def connect do
    case AMQP.Connection.open(Bunny.server_url) do
      {:ok, conn} ->
        Logger.info "Connected to RabbitMQ at #{Bunny.server_url}"
        Process.monitor(conn.pid)
        conn

      {:error, reason} ->
        Logger.error "Error connecting to RabbitMQ: #{inspect(reason)}"
        Process.send_after(self(), :connect, @reconnect_time)
        nil
    end
  end
end
