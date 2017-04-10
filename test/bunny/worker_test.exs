defmodule Bunny.WorkerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Twin

  alias Bunny.Worker

  defmodule Callback do
    def handle_message(payload, _meta, _state) do
      case payload do
        :ok -> :ok
        :raise -> raise "error"
        :throw -> throw :smth
        :exit  -> Process.exit(self(), :kill)
      end
    end
  end

  setup do
    stub(AMQP.Channel, :open, {:ok, %{pid: self()}})
    stub(AMQP.Basic, :qos, :ok)
    stub(AMQP.Queue, :declare, {:ok, :queue}) # main
    stub(AMQP.Queue, :declare, {:ok, :queue}) # retry
    stub(AMQP.Basic, :consume, {:ok, :tag})

    on_exit fn -> verify_stubs() end

    {:ok, state} = Worker.init({:conn, mod: Callback, queue: "x"})
    meta = %{delivery_tag: 1, headers: :undefined, content_type: :undefined, reply_to: :undefined}

    {:ok, state: state, meta: meta}
  end

  test "ok - run callback module and ack", %{state: state, meta: meta} do
    stub(AMQP.Basic, :ack, :ok)

    Worker.consume(:ok, meta, state)
  end

  test "raise - run callback module and publish retry", %{state: state, meta: meta} do
    stub(AMQP.Basic, :publish, :ok)
    stub(AMQP.Basic, :ack, :ok)

    assert capture_log(fn ->
      Worker.consume(:raise, meta, state)
    end) =~ "error"
  end

  test "throw - run callback module and publish retry", %{state: state, meta: meta} do
    stub(AMQP.Basic, :publish, :ok)
    stub(AMQP.Basic, :ack, :ok)

    assert capture_log(fn ->
      Worker.consume(:throw, meta, state)
    end) =~ "error"
  end

  test "exit - run callback module and publish retry", %{state: state, meta: meta} do
    stub(AMQP.Basic, :publish, :ok)
    stub(AMQP.Basic, :ack, :ok)

    # assert capture_log(fn ->
      Worker.consume(:exit, meta, state)
    # end) =~ "error"
  end
end
