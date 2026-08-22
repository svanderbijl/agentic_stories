defmodule AgenticStories.Engine.Narrator do
  @moduledoc """
  The Weaver's quieter duties after the story is live: residue (the traces
  an arriving player notices of events they missed) and recaps ("Previously…"
  for a returning player). Both are best-effort — failures simply produce
  nothing.
  """

  require Logger

  alias AgenticStories.Engine.CharacterMind
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Request
  alias AgenticStories.Stories.{Location, Story}

  @doc """
  One or two sentences of sensory aftermath for a player arriving where
  things happened without them — traces, never the events themselves.
  Returns `:none` when the missed beats leave nothing worth noticing.
  """
  @spec residue(Story.t(), Location.t(), [AgenticStories.Stories.Message.t()]) ::
          {:ok, String.t()} | :none
  def residue(%Story{}, %Location{}, []), do: :none

  def residue(%Story{} = story, %Location{} = location, missed_beats) do
    request = %Request{
      model: LLM.character_model(),
      system: """
      You narrate a story whose style is: #{story.style}
      Tone: #{story.tone}

      The player has just arrived somewhere, and things happened here while
      they were away. Write one or two short sentences, addressed to "you",
      describing only what an arriving person could actually notice — traces,
      residue, aftermath. Never narrate the events themselves, never name who
      did what, never include dialogue. If the events would leave nothing a
      newcomer could notice, reply with the single word NOTHING.
      """,
      messages: [
        %{
          role: :user,
          content: """
          The place: #{location.name} — #{location.description}

          What happened here while the player was away:

          #{CharacterMind.transcript(missed_beats)}
          """
        }
      ],
      max_tokens: 512
    }

    case LLM.chat(request, story_id: story.id, purpose: :residue) do
      {:ok, %{text: text}} ->
        case String.trim(text) do
          "" -> :none
          "NOTHING" <> _rest -> :none
          residue -> {:ok, residue}
        end

      {:error, _reason} ->
        :none
    end
  rescue
    exception ->
      Logger.warning("residue failed: #{Exception.message(exception)}")
      :none
  end

  @doc """
  Reads a player's beat for movement they narrated themselves ("I head for
  the porch") and resolves it to one of the story's places — so the world
  moves when the fiction says it does. Returns the location or `:none`.
  """
  @spec implied_move(Story.t(), [Location.t()], String.t()) :: {:ok, Location.t()} | :none
  def implied_move(%Story{}, locations, _content) when length(locations) < 2, do: :none

  def implied_move(%Story{} = story, locations, content) do
    places = Enum.map_join(locations, "\n", &"- #{&1.name}")

    request = %Request{
      model: LLM.character_model(),
      system: """
      You read one beat of an interactive story and decide whether the player
      moves themselves to another place IN THIS BEAT — actually going, not
      merely mentioning, pointing at, or planning to go later.

      The places of this story:
      #{places}

      Reply with exactly the name of the place the player moves to, and
      nothing else. If they do not move in this beat, reply with the single
      word NOTHING.
      """,
      messages: [%{role: :user, content: content}],
      max_tokens: 64
    }

    with {:ok, %{text: text}} <- LLM.chat(request, story_id: story.id, purpose: :move_intent),
         answer = text |> String.trim() |> String.trim_trailing("."),
         %Location{} = location <- AgenticStories.Stories.find_location(locations, answer) do
      {:ok, location}
    else
      _ -> :none
    end
  rescue
    _exception -> :none
  end

  @doc """
  "Previously, in …" — a short second-person recap of what the player has
  witnessed, for reopening a story after time away.
  """
  @spec recap(Story.t(), [AgenticStories.Stories.Message.t()]) :: {:ok, String.t()} | :error
  def recap(%Story{}, []), do: :error

  def recap(%Story{} = story, witnessed_beats) do
    request = %Request{
      model: LLM.character_model(),
      system: """
      You write the "previously, in this story" recap for a work of
      interactive fiction titled "#{story.title}". Style: #{story.style}
      Tone: #{story.tone}

      Address the player as "you". Cover only what they have witnessed. One
      short paragraph, at most 90 words, ending on where things stood when
      they left. Plain prose only.
      """,
      messages: [
        %{role: :user, content: CharacterMind.transcript(witnessed_beats)}
      ],
      max_tokens: 512
    }

    case LLM.chat(request, story_id: story.id, purpose: :recap) do
      {:ok, %{text: text}} ->
        case String.trim(text) do
          "" -> :error
          recap -> {:ok, recap}
        end

      {:error, _reason} ->
        :error
    end
  rescue
    exception ->
      Logger.warning("recap failed: #{Exception.message(exception)}")
      :error
  end
end
