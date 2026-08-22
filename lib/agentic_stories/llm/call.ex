defmodule AgenticStories.LLM.Call do
  @moduledoc """
  One recorded LLM call: which story, for what purpose (weave, tick,
  consolidate, direct, residue, recap), which model, and what it cost in
  tokens. `story_id` is a plain integer on purpose — the ledger is telemetry,
  not domain data, and must never fail a story over referential integrity.
  """

  use Ecto.Schema

  schema "llm_calls" do
    field :story_id, :integer
    field :purpose, :string
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cached_tokens, :integer, default: 0

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
