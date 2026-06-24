TestLens.start(project: "test_lens_demo", dir: "test_lens_out")
TestLens.Ecto.attach([:demo, :repo])
TestLens.Phoenix.attach()
ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])
