defmodule Bunny.RealTest do
  use ExUnit.Case, async: false

  defmodule Callback do
    def handle_message(payload, meta, from) do
      case payload do
        "please-reply" ->
          Bunny.Worker.reply(from, "this-is-a-reply")
          send :exunit_current_test, {:replied, payload}

        "raise" ->
          send :exunit_current_test, {:raise, payload}
          case Bunny.header(meta, "x-bunny-retries") do
            1 -> Bunny.Worker.reply(from, "ok")
            _ -> raise "can't handle"
          end

        "bad-reply" ->
          send :exunit_current_test, {:bad_reply, payload}
          case Bunny.header(meta, "x-bunny-retries") do
            1 -> Bunny.Worker.reply(from, "ok")
            _ -> Bunny.Worker.reply(from, self()) # PID is not a valid payload
          end

        _ ->
          send :exunit_current_test, {:processing, payload}
      end
    end
  end

  setup_all do
    # setup queues
    {:ok, conn} = AMQP.Connection.open(Bunny.server_url)
    {:ok, pid} = Bunny.Worker.start_link(conn, mod: Callback, queue: "bunny.test")
    Bunny.Worker.stop(pid)
    AMQP.Connection.close(conn)

    :ok
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

    # close channel and connection after test
    on_exit fn ->
      AMQP.Channel.close(ch)
      AMQP.Connection.close(conn)
    end

    {:ok, ch: ch}
  end

  test "process message", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    # publish from another connection
    AMQP.Basic.publish(ch, "", "bunny.test", "basic-payload")

    assert_receive {:processing, "basic-payload"}

    Bunny.stop(conn)
  end

  test "reply to message (via defined reply queue)", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    {:ok, _} = AMQP.Queue.declare(ch, "bunny.test.replies")
    AMQP.Queue.purge(ch, "bunny.test.replies")
    {:ok, tag} = AMQP.Basic.consume(ch, "bunny.test.replies")
    AMQP.Basic.publish(ch, "", "bunny.test", "please-reply", reply_to: "bunny.test.replies")

    assert_receive {:replied, _}
    assert_receive {:basic_deliver, "this-is-a-reply", _}

    AMQP.Basic.cancel(ch, tag)
    Bunny.stop(conn)
  end

  test "reply to message (via autoreply queue)", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    # consume from special direct reply-to queue
    # see https://www.rabbitmq.com/direct-reply-to.html for reference
    {:ok, tag} = AMQP.Basic.consume(ch, "amq.rabbitmq.reply-to", nil, no_ack: true)
    AMQP.Basic.publish(ch, "", "bunny.test", "please-reply", reply_to: "amq.rabbitmq.reply-to")

    assert_receive {:replied, _}
    assert_receive {:basic_deliver, "this-is-a-reply", _}

    AMQP.Basic.cancel(ch, tag)
    Bunny.stop(conn)
  end

  test "in case of raise - push message to retry queue with x-bunny-retries header", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
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
    Bunny.stop(conn)
  end

  test "in case of raise - retry the same message few times", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    {:ok, tag} = AMQP.Basic.consume(ch, "amq.rabbitmq.reply-to", nil, no_ack: true)
    AMQP.Basic.publish(ch, "", "bunny.test", "raise", reply_to: "amq.rabbitmq.reply-to")

    assert_receive {:raise, _}
    assert_receive {:raise, _}, 5500
    assert_receive {:basic_deliver, "ok", _}

    AMQP.Basic.cancel(ch, tag)
    Bunny.stop(conn)
  end

  test "handle bad reply - i.e. error on channel", %{ch: ch} do
    {:ok, conn} = Bunny.start_link([
      [mod: Callback, queue: "bunny.test"]
    ])

    {:ok, tag} = AMQP.Basic.consume(ch, "amq.rabbitmq.reply-to", nil, no_ack: true)
    AMQP.Basic.publish(ch, "", "bunny.test", "bad-reply", reply_to: "amq.rabbitmq.reply-to")

    assert_receive {:bad_reply, _}
    assert_receive {:bad_reply, _}, 6500

    AMQP.Basic.cancel(ch, tag)
    Bunny.stop(conn)
  end
end
