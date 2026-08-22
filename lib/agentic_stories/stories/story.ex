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
    field :arc, :string
    field :tone, :string
    field :style, :string
    field :status, Ecto.Enum, values: [:weaving, :live, :finished, :failed], default: :weaving
    field :failure_reason, :string

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
    |> cast(attrs, [:title, :premise, :arc, :tone, :style])
    |> validate_required([:title, :premise, :arc, :tone, :style])
    |> put_change(:status, :live)
  end

  def failure_changeset(story, reason) do
    change(story, status: :failed, failure_reason: reason)
  end

  def finish_changeset(story) do
    change(story, status: :finished)
  end
end
