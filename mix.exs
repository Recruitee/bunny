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
      {:amqp, "~> 0.2.0-pre.1"},

      # dev & test
      {:mix_test_watch, "~> 0.2", only: :dev},
      {:twin, path: "~/code/twin"},
    ]
  end
end
