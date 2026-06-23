defmodule TestLens.MixProject do
  use Mix.Project

  @version "0.1.0"

  @source_url "https://github.com/handgemacht-ai/test_lens"

  def project do
    [
      app: :test_lens,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Render ExUnit tests as input → action → result, without rewriting them.",
      source_url: @source_url,
      package: package(),
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
