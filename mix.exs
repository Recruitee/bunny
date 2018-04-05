defmodule Bunny.Mixfile do
  use Mix.Project

  def project do
    [app: :bunny,
     version: "0.1.0",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def application do
    [applications: [:logger, :amqp]]
  end

  defp deps do
    [
      {:amqp, "~> 1.0.0"},
      {:rabbit_common,  "~> 3.7.3"},

      # dev & test
      {:mix_test_watch, "~> 0.2", only: :dev},
      {:twin, github: "recruitee/twin"},
    ]
  end
end
