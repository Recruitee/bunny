# Bunny

RabbitMQ client. Do **NOT** use this. Seriously, **don't**. You have been warned.

## Installation

1. Add `bunny` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:bunny, github: "recruitee/bunny"}]
    end
    ```

2. Ensure `bunny` is started before your application:

    ```elixir
    def application do
      [applications: [:bunny]]
    end
    ```


## Adding workers

```elixir
defmodule EasyWorker do
  use Bunny.Worker, queue: "easy-jobs"

  def process(payload) do
    :ok
  end
end

defmodule HardWorker do
  use Bunny.Worker, queue: "hardcore-stuff"

  def process(payload) do
    1/0
  end
end

# in your supervision tree

# ...
children = [
  supervisor(MyApp.Repo, []),
  supervisor(MyApp.Endpoint, []),

  # add Bunny listing workers
  supervisor(Bunny, [[workers: [EasyWorker, HardWorker]]])
]
# ...
```
