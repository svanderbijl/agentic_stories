defmodule AgenticStories.Stories.Message do
  @moduledoc """
  One beat of a story. `kind` says who and how: the player speaking, a
  character speaking (`:say`) or doing (`:act`), or the narrator (`:narration`).
  Only character messages carry a `character_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :kind, Ecto.Enum, values: [:player, :say, :act, :narration, :illustration]
    field :content, :string
    # Whether the player was present when this beat happened; set at creation
    # and never retroactively. The reading pane shows only witnessed beats.
    field :witnessed_by_player, :boolean, default: true
    # Chapter illustrations: the plate binary stays out of normal queries;
    # fetch it with Stories.get_illustration/1. content carries the caption.
    field :image, :binary, load_in_query: false
    field :image_type, :string

    belongs_to :story, AgenticStories.Stories.Story
    belongs_to :character, AgenticStories.Stories.Character
    belongs_to :location, AgenticStories.Stories.Location

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :kind,
      :content,
      :character_id,
      :location_id,
      :witnessed_by_player,
      :image,
      :image_type
    ])
    |> update_change(:content, &String.trim/1)
    |> validate_required([:kind, :content])
  end
end
