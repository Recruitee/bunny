defmodule Bunny.Mixfile do
  use Mix.Project

  def project do
    [app: :bunny,
     version: "0.1.1",
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
      {:amqp, "~> 0.2.0"},
      {:rabbit_common, github: "rabbitmq/rabbitmq-common", 
                       tag: "v3.7.0-rc.1", 
                       compile: "make clean all",
                       override: true},
      {:lager, "3.5.1"},
      {:jsx, "2.8.2"}, 
      {:ranch, "1.3.2", override: true},
      {:ranch_proxy_protocol, github: "heroku/ranch_proxy_protocol"},
      # dev & test
      {:mix_test_watch, "~> 0.2", only: :dev},
      {:twin, github: "recruitee/twin"},
    ]
  end
end
