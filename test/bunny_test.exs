defmodule BunnyTest do
  use ExUnit.Case
  doctest Bunny

  defmodule W1 do
    use Bunny.Worker, queue: "bunny.test.q1"

    def perform(payload) do
      send :bunny_test_01, {:resp, payload}
    end
  end

  defmodule W2 do
    use Bunny.Worker, queue: "bunny.test.q2"

    def perform(payload) do
      1/0
    end
  end

  setup do
    # start with clean state
    {:ok, conn} = AMQP.Connection.open
    {:ok, ch} = AMQP.Channel.open(conn)

    AMQP.Queue.delete(ch, "bunny.test.q1")
    AMQP.Queue.delete(ch, "bunny.test.q1.retry")
    AMQP.Queue.delete(ch, "bunny.test.q1.dead")

    AMQP.Queue.delete(ch, "bunny.test.q2")
    AMQP.Queue.delete(ch, "bunny.test.q2.retry")
    AMQP.Queue.delete(ch, "bunny.test.q2.dead")

    # start Bunny
    Bunny.start_link(workers: [W1, W2])

    :ok
  end

  test "connection process alive" do
    assert Process.whereis(Bunny.Connection)
  end

  test "worker process alive" do
    assert Process.whereis(W1)
    assert Process.whereis(W2)
  end

  test "process message with success" do
    {:ok, conn} = AMQP.Connection.open
    {:ok, ch} = AMQP.Channel.open(conn)

    Process.register(self(), :bunny_test_01)
    AMQP.Basic.publish ch, "", "bunny.test.q1", "hello"

    assert_receive {:resp, "hello"}
  end

  test "process message with error" do
    {:ok, conn} = AMQP.Connection.open
    {:ok, ch} = AMQP.Channel.open(conn)

    AMQP.Basic.publish ch, "", "bunny.test.q2", "nooooo"
    # TODO: check retry queue message
  end
end
