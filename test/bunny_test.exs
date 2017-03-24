defmodule BunnyTest do
  use ExUnit.Case
  doctest Bunny

  defmodule OkWorker do
    use Bunny.Worker, queue: "bunny.test.ok"

    def process(payload) do
      Monkey.send {:i_am_done, payload}
      :ok
    end
  end

  defmodule ErrorWorker do
    use Bunny.Worker, queue: "bunny.test.error"

    def process(payload) do
      Monkey.send {:trying, payload}
      1/0
      Monkey.send {:nope, payload}
    end
  end

  setup do
    # start with clean state
    Monkey.delete_queues("bunny.test.ok")
    Monkey.delete_queues("bunny.test.error")
    Monkey.bind()

    # start Bunny
    Bunny.start_link(workers: [OkWorker, ErrorWorker])

    :ok
  end

  test "connection process alive" do
    assert Process.alive?(Process.whereis(Bunny.Connection))
  end

  test "worker processes alive" do
    assert Process.alive?(Process.whereis(OkWorker))
    assert Process.alive?(Process.whereis(ErrorWorker))
  end

  test "process message with success" do
    Monkey.publish "", "bunny.test.ok", "hello"
    assert_receive {:i_am_done, "hello"}
  end

  test "process message with error" do
    Monkey.publish "", "bunny.test.error", "nooooo"
    assert_receive {:trying, "nooooo"}
    refute_receive {:nope, _}
  end
end
