defmodule AgenticStories.Repo do
  use Ecto.Repo,
    otp_app: :agentic_stories,
    adapter: Ecto.Adapters.Postgres
end
