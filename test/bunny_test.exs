defmodule BunnyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule OkWorker do
    use Bunny.Worker, queue: "bunny.test.ok"

    def process(payload, _meta) do
      Monkey.send {:i_am_done, payload}
      :ok
    end
  end

  defmodule ErrorWorker do
    use Bunny.Worker, queue: "bunny.test.error",
                      retry: &retry_strategy/1

    def process(payload, meta) do
      Monkey.send {:trying, payload, retries(meta)}
      _ = 1/0
      Monkey.send {:nope, payload}
    end

    defp retry_strategy(count) do
      if count < 5, do: count * 100, else: :dead
    end
  end

  defmodule OnlyOnceWorker do
    use Bunny.Worker, queue: "bunny.test.once",
                      retry: false

    def process(_payload, _meta) do
      Monkey.send :once
      _ = 1/0
    end
  end

  setup do
    # start with clean state
    Monkey.delete_queues("bunny.test.ok")
    Monkey.delete_queues("bunny.test.error")
    Monkey.delete_queues("bunny.test.once")
    Monkey.bind()

    # start Bunny
    Bunny.start_link(workers: [OkWorker, ErrorWorker, OnlyOnceWorker])

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
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "oups"
      assert_receive {:trying, "oups", 0}
      assert_receive {:trying, "oups", 1}
      assert_receive {:trying, "oups", 2}, 200
      assert_receive {:trying, "oups", 3}, 300
      assert_receive {:trying, "oups", 4}, 400
      assert_receive {:trying, "oups", 5}, 500
      refute_receive {:nope, _}
    end) =~ "error"

    assert Monkey.count("bunny.test.error") == 0
    assert Monkey.count("bunny.test.error.retry") == 0
    assert Monkey.count("bunny.test.error.dead") == 1
  end

  test "do not retry if retry: false" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.once", "one"
      assert_receive :once
      refute_receive :once, 300

      assert Monkey.count("bunny.test.once") == 0
      assert Monkey.count("bunny.test.once.retry") == 0
      assert Monkey.count("bunny.test.once.dead") == 1
    end) =~ "error"
  end
end
