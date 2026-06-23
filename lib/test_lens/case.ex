defmodule TestLens.Case do
  @moduledoc """
  Mix into an ExUnit test module to auto-begin a capture for every test:

      use TestLens.Case

  This adds a single `setup` hook. It does not replace your existing case
  template — keep `use MyApp.DataCase` / `use MyAppWeb.ConnCase` as well.
  """

  defmacro __using__(_opts) do
    quote do
      setup context do
        TestLens.begin(context)
        :ok
      end
    end
  end
end
