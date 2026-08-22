Mox.defmock(AgenticStories.LLM.Mock, for: AgenticStories.LLM)
Mox.defmock(AgenticStories.Imagery.Mock, for: AgenticStories.Imagery)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AgenticStories.Repo, :manual)
