defmodule Bunny.Mixfile do
  use Mix.Project

  def project do
    [app: :bunny,
     version: "0.1.0",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     elixirc_paths: elixirc_paths(Mix.env),
     deps: deps()]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  def application do
    [applications: [:logger, :amqp]]
  end

  defp deps do
    [
      {:amqp, "~> 0.2.0-pre.1"}
    ]
  end
end
