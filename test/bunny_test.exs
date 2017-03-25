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
                      retry: false

    def process(payload, _meta) do
      case payload do
        "raise"   -> _ = 1/0
        "throw"   -> throw :foo
        "exit"    -> Process.exit(self(), :blowup)
        "ok"      -> :ok
        "ok+"     -> {:ok, 42}
        "error"   -> :error
        "error+"  -> {:error, :smth}
      end
    end
  end

  defmodule RetryWorker do
    use Bunny.Worker, queue: "bunny.test.retry",
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
    Monkey.delete_queues("bunny.test.retry")
    Monkey.delete_queues("bunny.test.once")
    Monkey.bind()

    # start Bunny
    Bunny.start_link(workers: [
      OkWorker,
      ErrorWorker,
      RetryWorker,
      OnlyOnceWorker
    ])

    :ok
  end

  test "connection process alive" do
    assert Process.alive?(Process.whereis(Bunny.Connection))
  end

  test "worker processes alive" do
    assert Process.alive?(Process.whereis(OkWorker))
    assert Process.alive?(Process.whereis(ErrorWorker))
    assert Process.alive?(Process.whereis(ErrorWorker))
    assert Process.alive?(Process.whereis(RetryWorker))
  end

  test "process message with success" do
    Monkey.publish "", "bunny.test.ok", "hello"
    assert_receive {:i_am_done, "hello"}

    assert Monkey.count("bunny.test.ok") == 0
    assert Monkey.count("bunny.test.ok.retry") == 0
    assert Monkey.count("bunny.test.ok.dead") == 0
  end

  test "process message with retries" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.retry", "oups"
      assert_receive {:trying, "oups", 0}
      assert_receive {:trying, "oups", 1}
      assert_receive {:trying, "oups", 2}, 200
      assert_receive {:trying, "oups", 3}, 300
      assert_receive {:trying, "oups", 4}, 400
      assert_receive {:trying, "oups", 5}, 500
      refute_receive {:nope, _}
    end) =~ "error"

    assert Monkey.count("bunny.test.retry") == 0
    assert Monkey.count("bunny.test.retry.retry") == 0
    assert Monkey.count("bunny.test.retry.dead") == 1
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


  test "handle raise" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "raise"
      :timer.sleep(50)
      assert Monkey.counts("bunny.test.error") == {0,0,1}
    end) =~ "error"
  end

  test "handle throw" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "throw"
      :timer.sleep(50)
      assert Monkey.counts("bunny.test.error") == {0,0,1}
    end) =~ "error"
  end

  test "handle exit" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "exit"
      :timer.sleep(50)
      assert Monkey.counts("bunny.test.error") == {0,0,1}
    end) =~ "error"
  end

  test "handle ok" do
    Monkey.publish "", "bunny.test.error", "ok"
    :timer.sleep(50)
    assert Monkey.counts("bunny.test.error") == {0,0,0}
  end

  test "handle ok+" do
    Monkey.publish "", "bunny.test.error", "ok+"
    :timer.sleep(50)
    assert Monkey.counts("bunny.test.error") == {0,0,0}
  end

  test "handle error" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "error"
      :timer.sleep(50)
      assert Monkey.counts("bunny.test.error") == {0,0,1}
    end) =~ "error"
  end

  test "handle error+" do
    assert capture_log(fn ->
      Monkey.publish "", "bunny.test.error", "error+"
      :timer.sleep(50)
      assert Monkey.counts("bunny.test.error") == {0,0,1}
    end) =~ "error"
  end
end
