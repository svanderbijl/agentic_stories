defmodule AgenticStories.Stories.MessageWitness do
  @moduledoc """
  Records that a character was present when a beat happened. Written once at
  message creation and never retroactively — a character's memory is exactly
  the beats they have witness rows for (plus location-less legacy beats).
  """

  use Ecto.Schema

  @primary_key false
  schema "message_witnesses" do
    belongs_to :message, AgenticStories.Stories.Message
    belongs_to :character, AgenticStories.Stories.Character
  end
end
