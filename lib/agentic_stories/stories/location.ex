defmodule AgenticStories.Stories.Location do
  @moduledoc """
  A place in a story, inferred from the seed by the Weaver. Locations are the
  grain of witnessing: characters and the player are always at exactly one,
  and a beat is seen only by whoever is there.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "locations" do
    field :name, :string
    field :description, :string

    belongs_to :story, AgenticStories.Stories.Story

    timestamps(type: :utc_datetime)
  end

  def changeset(location, attrs) do
    location
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
  end
end
