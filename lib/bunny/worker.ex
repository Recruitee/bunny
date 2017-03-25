defmodule Bunny.Worker do
  ## BEHAVIOUR SPEC
  @callback process(payload :: binary, meta :: map) :: no_return


  ## UNNECESSARY MACRO SUGAR

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour Bunny.Worker
      import Bunny.Helpers

      def start_link do
        Bunny.Worker.start_link(__MODULE__, unquote(opts))
      end
    end
  end


  ## CLIENT API

  use GenServer
  require Logger
  alias Bunny.Helpers

  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, {module, opts}, name: module)
  end

  ## CALLBACKS

  @default_prefetch     1
  @default_job_timeout  60 * 60 * 1000 # 1h
  @default_retry        :default

  @suffix_retry ".retry"
  @suffix_dead  ".dead"


  def init({module, opts}) do
    queue         = Keyword.fetch!(opts, :queue)
    queue_retry   = Keyword.get(opts, :queue_retry, queue <> @suffix_retry)
    queue_dead    = Keyword.get(opts, :queue_dead,  queue <> @suffix_dead)
    prefetch      = Keyword.get(opts, :prefetch, @default_prefetch)
    retry         = Keyword.get(opts, :retry, @default_retry)
    job_timeout   = Keyword.get(opts, :job_timeout, @default_job_timeout)

    {:ok, conn} = Bunny.Connection.get
    {:ok, ch} = create_channel(conn, prefetch)

    # create tasks queue
    create_queue(ch, queue)

    # create retry queue
    create_queue(ch, queue_retry, [
      arguments: [
        {"x-dead-letter-exchange",    :longstr, ""},
        {"x-dead-letter-routing-key", :longstr, queue}
      ]
    ])

    # create dead letters queue
    create_queue(ch, queue_dead)

    # subscribe to messages
    {:ok, _tag} = AMQP.Basic.consume(ch, queue)

    # trap spawned workers exits
    Process.flag(:trap_exit, true)

    {:ok, %{
      module: module,
      conn:   conn,
      ch:     ch,
      jobs:   %{},

      queue:        queue,
      queue_retry:  queue_retry,
      queue_dead:   queue_dead,
      retry:        retry,
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
      res = process(state.module, payload, meta)
      send worker, {:finished, self(), res}
    end

    # kill after timeout reached
    :timer.kill_after(state.job_timeout, pid)

    job = %{payload: payload, meta: meta}

    {:noreply, %{state | jobs: Map.put(state.jobs, pid, job)}}
  end

  def handle_info({:finished, pid, result}, state) do
    {job, jobs} = Map.pop(state.jobs, pid)

    case result do
      {:error, {:exception, error, trace}} ->
        Logger.error "Job [#{state.module}] exception: #{inspect(error)}\n#{Exception.format_stacktrace(trace)}"
        retry(state, job)

      {:error, {:throw, msg, reason}} ->
        Logger.error "Job [#{state.module}] unexepcted throw: #{inspect(msg)} - #{inspect(reason)}"
        retry(state, job)

      {:error, {:exit, reason}} ->
        Logger.error "Job [#{state.module}] process EXIT: #{inspect(reason)}"
        retry(state, job)

      {:error, reason} ->
        Logger.error "Job [#{state.module}] returned {:error, #{inspect(reason)}}"
        retry(state, job)

      :error ->
        Logger.error "Job [#{state.module}] retruned :error"
        retry(state, job)

      {:ok, _} ->
        ack(state, job)

      :ok ->
        ack(state, job)
    end

    {:noreply, %{state | jobs: jobs}}
  end

  def handle_info({:EXIT, pid, :normal}, state) do
    # ignore normal exits
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if Map.has_key?(state.jobs, pid) do
      send self(), {:finished, pid, {:error, {:exit, reason}}}
    end

    {:noreply, state}
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

  defp process(module, payload, meta) do
    apply(module, :process, [payload, meta])
  rescue
    error ->
      trace = System.stacktrace
      {:error, {:exception, error, trace}}
  catch
    msg, reason ->
      {:error, {:throw, msg, reason}}
  end

  defp retry_delay(false, _), do: :dead
  defp retry_delay(fun, count) when is_function(fun), do: fun.(count)
  defp retry_delay(:default, count) do
    if count < 25 do
      # borrowed from sidekiq
      # https://github.com/mperham/sidekiq/commit/b08696bd504c5f8e5ee16ff5b7ba39b9ec66ca1c
      :math.pow(count, 4) + 15 + (:rand.uniform(30) * (count + 1)) * 1_000
    else
      :dead
    end
  end

  defp ack(state, job) do
    AMQP.Basic.ack(state.ch, job.meta.delivery_tag)
  end

  defp retry(state, job) do
    retries = Helpers.retries(job.meta)

    case retry_delay(state.retry, retries) do
      :dead ->
        AMQP.Basic.publish(state.ch, "", state.queue_dead, job.payload, [
          persistent: true
        ])
      exp ->
        AMQP.Basic.publish(state.ch, "", state.queue_retry, job.payload, [
          expiration: "#{exp}",
          persistent: true,
          headers: [
            "x-bunny-retries": retries + 1
          ]
        ])
    end

    ack(state, job)
  end
end
