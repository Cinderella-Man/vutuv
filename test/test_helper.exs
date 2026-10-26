Code.require_file("support/line_buffered_io.exs", __DIR__)
Vutuv.Test.LineBufferedIO.install()

ExUnit.start(max_cases: 2)
Ecto.Adapters.SQL.Sandbox.mode(Vutuv.Repo, :manual)
