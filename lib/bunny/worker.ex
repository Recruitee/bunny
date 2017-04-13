defmodule Bunny.Worker do
  ## BEHAVIOUR SPEC
  @callback handle_message(payload :: binary, meta :: map) :: any


  # ## UNNECESSARY MACRO SUGAR
  #
  # defmacro __using__(opts) do
  #   quote location: :keep do
  #     @behaviour Bunny.Worker
  #     import Bunny.Helpers
  #
  #     def start_link do
  #       Bunny.Worker.start_link(__MODULE__, unquote(opts))
  #     end
  #   end
  # end
  #
  #
  ## CLIENT API

  use GenServer
  require Logger

  def start_link(%AMQP.Connection{} = conn, opts) do
    GenServer.start_link(__MODULE__, {conn, opts}, [])
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  ## CALLBACKS

  @default_prefetch   10
  @default_timeout    60 * 60 * 1000 # 1h

  @suffix_retry ".retry"

  @amqp_basic   Twin.get(AMQP.Basic)
  @amqp_channel Twin.get(AMQP.Channel)
  @amqp_queue   Twin.get(AMQP.Queue)

  def init({conn, opts}) do
    Logger.info "Starting worker: #{inspect(opts)}"

    # configuration handling
    mod           = Keyword.fetch!(opts, :mod)

    queue         = Keyword.fetch!(opts, :queue)
    queue_retry   = Keyword.get(opts, :queue_retry, queue <> @suffix_retry)
    prefetch      = Keyword.get(opts, :prefetch, @default_prefetch)
    timeout       = Keyword.get(opts, :job_timeout, @default_timeout)

    # channel setup
    {:ok, ch} = @amqp_channel.open(conn)
    Process.link(ch.pid)
    @amqp_basic.qos(ch, prefetch_count: prefetch)

    setup_queues(ch, queue, queue_retry)

    # subscribe to messages
    {:ok, tag} = @amqp_basic.consume(ch, queue)

    {:ok, %{
      ch: ch,
      tag: tag,
      mod: mod,

      queue:        queue,
      queue_retry:  queue_retry,
      timeout:      timeout
    }}
  end

  def setup_queues(ch, queue, queue_retry) do
    # create main task queue
    {:ok, _} = @amqp_queue.declare(ch, queue, durable: true)

    # create retry queue
    {:ok, _} = @amqp_queue.declare(ch, queue_retry, durable: true, arguments: [
      {"x-dead-letter-exchange",    :longstr, ""},
      {"x-dead-letter-routing-key", :longstr, queue}
    ])
  end

  # AMQP callbacks

  def handle_info({:basic_consume_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_cancel, _}, state) do
    # TODO: Cancel jobs
    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    # spawn process for consuming this message
    spawn_link fn -> consume(payload, meta, state) end

    {:noreply, state}
  end

  def terminate(_reason, %{ch: ch, tag: tag}) do
    @amqp_basic.cancel(ch, tag)
    @amqp_channel.close(ch)
  end

  def consume(payload, meta, state) do
    # Quite o lot is happening here
    # First, trap EXIT signals from linked processes
    Process.flag(:trap_exit, true)

    # Then, spawn a process for calling calback module
    pid = spawn_link fn ->
      from = %{ch: state.ch, reply_to: meta.reply_to, correlation_id: meta.correlation_id}
      apply(state.mod, :handle_message, [payload, meta, from])
    end

    # Set a timeout after which that process will be killed
    :timer.kill_after(60_000, pid)

    # Now wait for EXIT messages
    receive do
      # In case of :normal exit simply ack the message
      {:EXIT, ^pid, :normal} ->
        @amqp_basic.ack(state.ch, meta.delivery_tag)

      # In case of error
      {:EXIT, ^pid, _reason} ->
        # Push the message into retry queue
        retries = Bunny.header(meta, "x-bunny-retries") || 0
        exp = expiration(retries)
        options =
          meta
          |> Map.merge(%{
            expiration: "#{exp}",
            persistent: true,
            headers: ["x-bunny-retries": retries + 1],
            content_type: meta.content_type
          })
          |> Map.to_list
        @amqp_basic.publish(state.ch, "", state.queue_retry, payload, options)

        # TODO: Store reason in headers
        # And then ack the original message
        @amqp_basic.ack(state.ch, meta.delivery_tag)

      # In case of other EXIT message just die
      # The job process will die too since it's linked
      {:EXIT, _pid, reason} ->
        Process.exit(self(), reason)
    end
  end

  defp expiration(count) do
    round(:math.pow(count, 4)) + (:rand.uniform(2) * (count + 1)) * 1_000
  end


  ## UTILS

  def reply(from, payload, meta \\ [])
  def reply(%{reply_to: :undefined}, _, _), do: :noop
  def reply(%{ch: ch, reply_to: reply_to, correlation_id: cid}, payload, meta) when is_binary(payload) do
    AMQP.Basic.publish(ch, "", reply_to, payload, meta ++ [correlation_id: cid])
  end
end
