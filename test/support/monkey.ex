defmodule Monkey do
  use GenServer

  ## API

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def bind(pid \\ self()) do
    GenServer.call(__MODULE__, {:bind, pid})
  end

  def send(msg) do
    GenServer.cast(__MODULE__, {:send, msg})
  end

  def delete_queues(name) do
    ch = ch()
    AMQP.Queue.delete(ch, name)
    AMQP.Queue.delete(ch, "#{name}.retry")
    AMQP.Queue.delete(ch, "#{name}.dead")
  end

  def publish(exchange, key, msg, opts \\ []) do
    AMQP.Basic.publish(ch(), exchange, key, msg, opts)
  end

  def count(queue) do
    AMQP.Queue.message_count(ch(), queue)
  end

  def ch do
    GenServer.call(__MODULE__, :ch)
  end

  ## CALLBACKS

  def init([]) do
    {:ok, conn} = AMQP.Connection.open()
    {:ok, ch} = AMQP.Channel.open(conn)

    {:ok, %{conn: conn, ch: ch, test: nil}}
  end

  def handle_call(:ch, _from, %{ch: ch} = state) do
    {:reply, ch, state}
  end


  def handle_call({:bind, pid}, _from, state) do
    flush()
    {:reply, :ok, %{state | test: pid}}
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
