defmodule Bunny.RealTest do
  use ExUnit.Case, async: false

  alias Bunny.Connection

  defmodule Callback do
    def handle_message(payload, _meta, from) do
      case payload do
        "please-reply" ->
          Bunny.Worker.reply(from, "this-is-a-reply")
          send :exunit_current_test, {:replied, payload}

        "raise" ->
          send :exunit_current_test, {:raise, payload}
          raise "can't handle"

        _ ->
          send :exunit_current_test, {:processing, payload}
      end
    end
  end

  setup do
    # register current test process as :exunit_current_test
    # there is no need to unregister - it will be unregistered
    # automatically when test process exits
    Process.register(self(), :exunit_current_test)

    # setup secondary channel for testing purposes
    {:ok, conn} = AMQP.Connection.open(Bunny.server_url)
    {:ok, ch} = AMQP.Channel.open(conn)

    # purge test queues
    AMQP.Queue.purge(ch, "bunny.test")
    AMQP.Queue.purge(ch, "bunny.test.retry")
    AMQP.Queue.purge(ch, "bunny.test.replies")

    # close channel and connection after test
    on_exit fn ->
      AMQP.Channel.close(ch)
      AMQP.Connection.close(conn)
    end

    {:ok, ch: ch}
  end

  test "process message", %{ch: ch} do
    {:ok, conn} = Connection.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    # publish from another connection
    AMQP.Basic.publish(ch, "", "bunny.test", "basic-payload")

    assert_receive {:processing, "basic-payload"}

    Connection.stop(conn)
  end

  test "reply to message (via defined reply queue)", %{ch: ch} do
    {:ok, conn} = Connection.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    {:ok, _} = AMQP.Queue.declare(ch, "bunny.test.replies")
    {:ok, tag} = AMQP.Basic.consume(ch, "bunny.test.replies")
    AMQP.Basic.publish(ch, "", "bunny.test", "please-reply", reply_to: "bunny.test.replies")

    assert_receive {:replied, _}
    assert_receive {:basic_deliver, "this-is-a-reply", _}

    AMQP.Basic.cancel(ch, tag)
    Connection.stop(conn)
  end

  test "reply to message (via autoreply queue)", %{ch: ch} do
    {:ok, conn} = Connection.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    # consume from special direct reply-to queue
    # see https://www.rabbitmq.com/direct-reply-to.html for reference
    {:ok, tag} = AMQP.Basic.consume(ch, "amq.rabbitmq.reply-to", nil, no_ack: true)
    AMQP.Basic.publish(ch, "", "bunny.test", "please-reply", reply_to: "amq.rabbitmq.reply-to")

    assert_receive {:replied, _}
    assert_receive {:basic_deliver, "this-is-a-reply", _}

    AMQP.Basic.cancel(ch, tag)
    Connection.stop(conn)
  end

  test "in case of raise - push message to retry queue with x-bunny-retries header", %{ch: ch} do
    {:ok, conn} = Connection.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    # consume from retry queue
    {:ok, tag} = AMQP.Basic.consume(ch, "bunny.test.retry")

    AMQP.Basic.publish(ch, "", "bunny.test", "raise", content_type: "application/msgpack")

    assert_receive {:basic_deliver, "raise", meta}
    assert meta.content_type == "application/msgpack"
    assert meta.expiration != :undefined
    assert Bunny.header(meta, "x-bunny-retries") == 1

    AMQP.Basic.cancel(ch, tag)
    Connection.stop(conn)
  end

  test "in case of raise - retry the same message few times", %{ch: ch} do
    {:ok, conn} = Connection.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    AMQP.Basic.publish(ch, "", "bunny.test", "raise", content_type: "application/msgpack")

    assert_receive {:raise, _}
    assert_receive {:raise, _}, 5500

    Connection.stop(conn)
  end
end
