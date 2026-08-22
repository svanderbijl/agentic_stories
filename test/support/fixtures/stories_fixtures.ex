defmodule AgenticStories.StoriesFixtures do
  @moduledoc """
  Test fixtures for the Stories context. Inserts skip the Weaver entirely so
  tests can start from any story state.
  """

  alias AgenticStories.Repo
  alias AgenticStories.Stories.{Character, Location, Message, Story}

  def story_fixture(attrs \\ %{}) do
    defaults = %{
      seed: "A lighthouse keeper finds a door at the bottom of the sea.",
      title: "The Door Below",
      premise: "A keeper discovers a door on the seabed that should not exist.",
      arc: "Curiosity pulls the keeper down; the door asks a price; what surfaces is changed.",
      tone: "quietly ominous, wondrous",
      style: "Spare, salt-worn prose.",
      status: :live
    }

    Story
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  def weaving_story_fixture(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.merge(%{status: :weaving, title: nil, premise: nil, arc: nil, tone: nil, style: nil})
    |> story_fixture()
  end

  def location_fixture(%Story{} = story, attrs \\ %{}) do
    defaults = %{
      story_id: story.id,
      name: "The Lamp Room",
      description: "Salt-bleached glass and the smell of hot brass."
    }

    Location
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  def character_fixture(%Story{} = story, attrs \\ %{}) do
    defaults = %{
      story_id: story.id,
      name: "Maren",
      persona: "The keeper's sister. Practical, worried, keeps lists of what the sea takes.",
      voice: "Clipped sentences, warm underneath.",
      agenda: "She has already opened the door once, and lied about it.",
      arc: "From gatekeeper of the secret to the one who finally tells it.",
      energy: 2
    }

    Character
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  def message_fixture(%Story{} = story, attrs \\ %{}) do
    defaults = %{
      story_id: story.id,
      kind: :narration,
      content: "The tide pulls back further than it should."
    }

    Message
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end
