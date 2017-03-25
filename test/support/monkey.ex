defmodule Monkey do
  use GenServer

  ## API

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def delete_queues(name) do
    GenServer.call(__MODULE__, {:delete_queues, name})
  end

  def bind(pid \\ self()) do
    GenServer.call(__MODULE__, {:bind, pid})
  end

  def publish(exchange, key, msg, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, key, msg, opts})
  end

  def send(msg) do
    GenServer.cast(__MODULE__, {:send, msg})
  end

  ## CALLBACKS

  def init([]) do
    {:ok, conn} = AMQP.Connection.open()
    {:ok, ch} = AMQP.Channel.open(conn)

    {:ok, %{conn: conn, ch: ch, test: nil}}
  end

  def handle_call({:delete_queues, name}, _from, %{ch: ch} = state) do
    AMQP.Queue.delete(ch, name)
    AMQP.Queue.delete(ch, "#{name}.retry")
    AMQP.Queue.delete(ch, "#{name}.dead")

    {:reply, :ok, state}
  end

  def handle_call({:bind, pid}, _from, state) do
    flush()
    {:reply, :ok, %{state | test: pid}}
  end

  def handle_call({:publish, exchange, key, msg, opts}, _from, %{ch: ch} = state) do
    AMQP.Basic.publish(ch, exchange, key, msg, opts)
    {:reply, :ok, state}
  end

  def handle_cast({:send, msg}, %{test: pid} = state) do
    send pid, msg
    {:noreply, state}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
