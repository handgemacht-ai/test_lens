defmodule TestLens.Sample do
  @moduledoc """
  Stand-in for an Ash-style command that returns `{:ok, _} | {:error, _}`,
  mirroring ash_knowledge_graph's function-call test shape so the demo can
  exercise the library without a real database.
  """

  @reserved ~w(main master)

  def create_branch(name) when is_binary(name) do
    cond do
      name in @reserved -> {:error, {:protected_branch, name}}
      Regex.match?(~r/\A[a-z0-9_\-]+\z/, name) -> {:ok, %{name: name, created: true}}
      true -> {:error, {:invalid_branch, name}}
    end
  end

  def create_branch(other), do: {:error, {:invalid_branch, other}}
end
