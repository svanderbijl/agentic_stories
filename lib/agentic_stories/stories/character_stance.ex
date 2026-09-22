defmodule AgenticStories.Stories.CharacterStance do
  @moduledoc """
  One immutable sentence of what a character will not give up.

  Append-only, like the journal, but it is policy rather than memory: the
  outcome of a bid, or a fact pinned while they were away from the player.
  Earlier sentences are never rewritten, and none of them are ever shown.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "character_stances" do
    field :content, :string

    belongs_to :character, AgenticStories.Stories.Character

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(stance, attrs) do
    stance
    |> cast(attrs, [:content])
    |> update_change(:content, &String.trim/1)
    |> validate_required([:content])
  end
end
