TestLens.start(project: "test_lens_demo", dir: "test_lens_out")
TestLens.Ecto.attach([:demo, :repo])
ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])
