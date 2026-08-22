defmodule AgenticStories.Stories.CharacterMemory do
  @moduledoc """
  One immutable block of a character's long-term memory: the compression of
  one epoch of witnessed beats, written once and never rewritten. The chain
  of blocks is append-only on purpose — it reads as a journal, early memories
  never degrade through re-compression, and the prompt prefix built from it
  stays byte-stable for provider caching.
  """

  use Ecto.Schema

  schema "character_memories" do
    field :content, :string

    belongs_to :character, AgenticStories.Stories.Character

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
