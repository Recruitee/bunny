defmodule BunnyInvalidConnectionTest do
  use ExUnit.Case, async: false

  defmodule OkWorker do
    use Bunny.Worker, queue: "bunny.test.ok"

    def process(payload, _meta) do
      Monkey.send {:done, payload}
      :ok
    end
  end

  setup do
    # start with clean state
    Monkey.delete_queues("bunny.test.ok")
    Monkey.create_queue("bunny.test.ok")
    Monkey.bind()

    Application.put_env(:bunny, :server_url, "amqp://localhost:80")

    # start Bunny
    {:ok, _} = Bunny.start_link(
      workers: [OkWorker]
    )

    :ok
  end

  test "handle invalid connection on start" do
    # publish message
    Monkey.publish "", "bunny.test.ok", "hi"
    # wait for worker to pick it up
    refute_receive {:done, "hi"}

    # fix connection
    Application.put_env(:bunny, :server_url, "amqp://localhost")

    assert_receive {:done, "hi"}, 2_000
  end
end
