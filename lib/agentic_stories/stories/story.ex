defmodule AgenticStories.Stories.Story do
  @moduledoc """
  A story woven from a player's seed. Born `:weaving`, it becomes `:live`
  once the Weaver has produced its title, premise, arc, tone, style, and
  cast — or `:failed` if the weave came apart.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "stories" do
    field :title, :string
    field :seed, :string
    field :premise, :string
    # Who the player is in this story, in the third person. Every character
    # is told it: an unnamed, bodiless player is a vacuum the cast fills by
    # assuming the player's own role.
    field :protagonist, :string
    field :arc, :string
    field :tone, :string
    field :style, :string
    field :status, Ecto.Enum, values: [:weaving, :live, :finished, :failed], default: :weaving
    field :failure_reason, :string
    # Likeness for plates (and the "You" card). Fetch the binary with
    # Stories.get_player_avatar/1; a non-nil player_avatar_type is the flag.
    field :player_avatar, :binary, load_in_query: false
    field :player_avatar_type, :string
    # Full character-design sheet for the player, same as the cast's boards.
    # Fetch with Stories.get_player_board/1.
    field :player_board, :binary, load_in_query: false
    field :player_board_type, :string
    # How the player looks now. Nil falls back to the woven `protagonist`.
    field :player_appearance, :string

    has_many :characters, AgenticStories.Stories.Character
    has_many :messages, AgenticStories.Stories.Message
    has_many :locations, AgenticStories.Stories.Location
    belongs_to :player_location, AgenticStories.Stories.Location

    timestamps(type: :utc_datetime)
  end

  def seed_changeset(story, attrs) do
    story
    |> cast(attrs, [:seed])
    |> update_change(:seed, &String.trim/1)
    |> validate_required([:seed])
    |> validate_length(:seed, min: 3, max: 4_000)
  end

  def weave_changeset(story, attrs) do
    story
    |> cast(attrs, [:title, :premise, :protagonist, :arc, :tone, :style])
    |> validate_required([:title, :premise, :arc, :tone, :style])
    |> put_change(:status, :live)
  end

  def failure_changeset(story, reason) do
    change(story, status: :failed, failure_reason: reason)
  end

  def finish_changeset(story) do
    change(story, status: :finished)
  end

  def player_avatar_changeset(story, binary, content_type) do
    change(story, player_avatar: binary, player_avatar_type: content_type)
  end

  def player_board_changeset(story, binary, content_type) do
    change(story, player_board: binary, player_board_type: content_type)
  end
end
