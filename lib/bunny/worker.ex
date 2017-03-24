defmodule Bunny.Worker do
  ## BEHAVIOUR SPEC
  @callback process(payload :: binary) :: no_return


  ## UNNECESSARY MACRO SUGAR

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour Bunny.Worker

      def start_link do
        Bunny.Worker.start_link(__MODULE__, unquote(opts))
      end
    end
  end


  ## CLIENT API

  use GenServer
  require Logger

  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, {module, opts}, name: module)
  end

  ## CALLBACKS

  @default_prefetch_count 1
  @default_retry_delay    10
  @default_retry_limit    5
  @default_job_timeout    60 * 60 * 1000 # 1h

  @suffix_retry ".retry"
  @suffix_dead  ".dead"


  def init({module, opts}) do
    queue           = Keyword.fetch!(opts, :queue)
    queue_retry     = opts[:queue_retry] || queue <> @suffix_retry
    queue_dead      = opts[:queue_dead]  || queue <> @suffix_dead
    prefetch_count  = opts[:prefetch_count] || @default_prefetch_count
    retry_delay     = opts[:retry_delay] || @default_retry_delay
    retry_limit     = opts[:retry_limit] || @default_retry_limit
    job_timeout     = opts[:job_timeout] || @default_job_timeout

    {:ok, conn} = Bunny.Connection.get
    {:ok, ch} = create_channel(conn, prefetch_count)

    # create tasks queue
    create_queue(ch, queue)

    # create retry queue
    create_queue(ch, queue_retry, [
      {"x-dead-letter-exchange",    :longstr, ""},
      {"x-dead-letter-routing-key", :longstr, queue}
    ])

    # create dead letters queue
    create_queue(ch, queue_dead)

    # subscribe to messages
    {:ok, _tag} = AMQP.Basic.consume(ch, queue)

    {:ok, %{
      module: module,
      conn:   conn,
      ch:     ch,
      jobs:   %{},

      queue:        queue,
      queue_retry:  queue_retry,
      queue_dead:   queue_dead,
      retry_delay:  retry_delay,
      retry_limit:  retry_limit,
      job_timeout:  job_timeout
    }}
  end

  def handle_info({:basic_consume_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_cancel, _}, chan) do
    {:stop, :normal, chan}
  end

  def handle_info({:basic_cancel_ok, _}, chan) do
    {:noreply, chan}
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    worker = self()

    pid = spawn_link fn ->
      res = perform(state.module, payload, meta)
      send worker, {:finished, self(), res, payload}
    end

    # kill after timeout reached
    :timer.kill_after(state.job_timeout, pid)

    job = %{meta: meta}

    {:noreply, %{state | jobs: Map.put(state.jobs, pid, job)}}
  end

  def handle_info({:finished, pid, result, payload}, state) do
    {job, jobs} = Map.pop(state.jobs, pid)

    if ok?(result) do
      # just ack
      AMQP.Basic.ack(state.ch, job.meta.delivery_tag)
    else
      # publish to retry queue
      opts = [expiration: "#{state.retry_delay}", persistent: true]
      AMQP.Basic.publish(state.ch, "", state.queue_retry, payload, opts)

      # ack
      AMQP.Basic.ack(state.ch, job.meta.delivery_tag)
    end

    {:noreply, %{state | jobs: jobs}}
  end

  ## INTERNALS

  defp create_channel(conn, prefetch_count) do
    with {:ok, channel} <- AMQP.Channel.open(conn) do
      AMQP.Basic.qos(channel, prefetch_count: prefetch_count)
      {:ok, channel}
    end
  end

  defp create_queue(ch, name, opts \\ []) do
    {:ok, _} = AMQP.Queue.declare(ch, name, opts ++ [durable: true])
  end

  defp ok?(:ok), do: true
  defp ok?({:ok, _}), do: true
  defp ok?(_), do: false

  def perform(module, payload, meta) do
    apply(module, :perform, [payload])
  rescue
    error ->
      trace = System.stacktrace
      Logger.error "Job [#{module}] exception: #{inspect(error)}\n#{Exception.format_stacktrace(trace)}"
      {:error, error}
  catch
    _, reason ->
      Logger.error "Job [#{module}] catch: #{inspect(reason)}"
      {:error, reason}
  end
end
