defmodule Bunny.ConnectionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Twin

  alias Bunny.Connection

  test "stop workers on connection error" do
    stub(AMQP.Connection, :open, {:error, "timeout"})
    stub(Bunny.Worker, :stop, :ok) # w1
    stub(Bunny.Worker, :stop, :ok) # w2

    assert capture_log(fn ->
      Connection.handle_info(:connect, %{workers: [:w1, :w2]})
    end) =~ "warn"

    assert_called Bunny.Worker, :stop, [:w1]
    assert_called Bunny.Worker, :stop, [:w2]
  end
end
