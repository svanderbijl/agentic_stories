defmodule AgenticStories.Stories.Character do
  @moduledoc """
  An AI-driven member of a story's cast. `energy` is the persisted fuel for
  the character's agent process: ticks spend it, player interaction refills it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "characters" do
    field :name, :string
    field :persona, :string
    field :voice, :string
    # The hidden want. Fed to the character's own mind, NEVER to the player UI.
    field :agenda, :string
    # Their own journey through the story — also mind-only, never the UI.
    field :arc, :string
    # What they look like — shared by portrait prompts and scene plates so
    # every image of this character agrees with the others.
    field :appearance, :string
    # A one-tick whisper from the Director; never persisted.
    field :nudge, :string, virtual: true
    field :energy, :integer, default: 0
    # The image binary never rides along on normal queries; fetch it with
    # Stories.get_avatar/1. A non-nil avatar_type is the "has an avatar" flag.
    field :avatar, :binary, load_in_query: false
    field :avatar_type, :string
    # Long-term memory lives in append-only CharacterMemory blocks;
    # memory_beats counts how many witnessed beats are already folded in.
    field :memory_beats, :integer, default: 0

    belongs_to :story, AgenticStories.Stories.Story
    belongs_to :location, AgenticStories.Stories.Location
    has_many :memories, AgenticStories.Stories.CharacterMemory

    timestamps(type: :utc_datetime)
  end

  def changeset(character, attrs) do
    character
    |> cast(attrs, [:name, :persona, :voice, :agenda, :arc, :appearance, :energy, :location_id])
    |> validate_required([:name, :persona])
    |> validate_number(:energy, greater_than_or_equal_to: 0)
  end

  def avatar_changeset(character, binary, content_type) do
    change(character, avatar: binary, avatar_type: content_type)
  end
end
