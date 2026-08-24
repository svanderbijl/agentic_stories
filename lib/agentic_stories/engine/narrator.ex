defmodule AgenticStories.Engine.Narrator do
  @moduledoc """
  The Weaver's quieter duties after the story is live: residue (the traces
  an arriving player notices of events they missed), recaps ("Previously…"
  for a returning player), and the tableau behind a player-requested picture.
  All best-effort — failures simply produce nothing.
  """

  require Logger

  alias AgenticStories.Engine.CharacterMind
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Request
  alias AgenticStories.Stories.{Character, Location, Message, Story}

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
      did what, never include dialogue. Write in the story's language — the
      language of the beats you are shown. If the events would leave nothing
      a newcomer could notice, reply with the single word NOTHING.
      """,
      messages: [
        %{
          role: :user,
          content: """
          The place: #{location.name}#{if location.description, do: " — #{location.description}"}

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
  Reads the story back and describes the CURRENT moment as one photographic
  tableau — who is here, how they stand, what they are wearing, the light and
  the state of the place — for the illustrator. This is what the player gets
  when they ask for a picture of the scene, so it reads the record rather
  than guessing from the cast list: a coat shrugged off ten beats ago is off.

  Returns `{scene, caption}`, or `:none` when the read-back fails — a picture
  is never worth crashing a story over.
  """
  @spec tableau(Story.t(), Location.t() | nil, [Character.t()], [Message.t()]) ::
          {:ok, String.t(), String.t()} | :none
  def tableau(%Story{} = story, location, characters, beats) do
    request = %Request{
      model: LLM.character_model(),
      system: """
      You are the eye of the illustrator for a story whose tone is:
      #{story.tone}

      You will be given a place, the people who are there, and the record of
      the story so far. Describe THE MOMENT THE RECORD ENDS as a single
      photograph, for an illustrator who has read none of it.

      Write a short caption in the story's voice and language on the first
      line, like so:

          CAPTION: The stranger takes the beer

      Then, from the next line on, the photograph itself. Name each person and say where they stand in
      relation to each other and to the room, their posture, what their hands
      are doing, where they are looking. Say what they are WEARING as the
      record has left them — clothing put on, taken off, torn or soaked in
      the story overrides how they were first described. Say what the place
      looks like right now: light, weather, time of day, what is on the
      floor and the walls, what has been moved or broken.

      Concrete nouns and visible facts only. No dialogue, no names of
      emotions, no backstory, no words about what anyone intends. Never add
      a person who is not in the list of who is here. The photograph is for
      the illustrator: write it in English, whatever language the story is
      told in.
      """,
      messages: [
        %{
          role: :user,
          content: """
          #{tableau_place(location)}Who is here:
          #{tableau_cast(characters)}
          The record so far:

          #{CharacterMind.transcript(beats)}
          """
        }
      ],
      max_tokens: 1024
    }

    case LLM.chat(request, story_id: story.id, purpose: :tableau) do
      {:ok, %{text: text}} -> read_tableau(text, location)
      {:error, _reason} -> :none
    end
  rescue
    exception ->
      Logger.warning("tableau failed: #{Exception.message(exception)}")
      :none
  end

  # Lenient on purpose: the caption line is a nicety, the tableau is the
  # point. A model that skips the label has still written the photograph.
  defp read_tableau(text, location) do
    {caption, scene} =
      case String.split(String.trim(text || ""), "\n", parts: 2) do
        ["CAPTION:" <> caption, scene] -> {String.trim(caption), String.trim(scene)}
        _ -> {nil, String.trim(text || "")}
      end

    case scene do
      "" -> :none
      scene -> {:ok, scene, caption || (location && location.name) || "The scene"}
    end
  end

  defp tableau_place(nil), do: ""

  # a place a character opened mid-story has no description yet
  defp tableau_place(%Location{description: nil} = location) do
    "The place: #{location.name}\n\n"
  end

  defp tableau_place(%Location{} = location) do
    "The place: #{location.name} — #{location.description}\n\n"
  end

  defp tableau_cast([]), do: "- nobody but the player\n"

  defp tableau_cast(characters) do
    Enum.map_join(characters, "\n", fn character ->
      "- #{character.name}: #{character.appearance || character.persona}"
    end)
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
  Reads a character's own beat for movement they narrated but did not
  execute — "Vivian follows Jack into the kitchen" — and resolves it to one
  of the story's places. The arrow (`-> The Kitchen: …`) is the only path a
  character has to `move/4`, and a model telling a story writes the prose,
  not the arrow. Without this, the fiction says she followed you and the
  world keeps her where she was: you walk to the kitchen alone, forever.

  Costs nothing on the overwhelming majority of beats: a beat that never
  names another place cannot be a departure, and that is decided in code
  before any call is made.
  """
  @spec implied_departure(Story.t(), Character.t(), [Location.t()], String.t()) ::
          {:ok, Location.t()} | :none
  def implied_departure(story, character, locations, text)

  def implied_departure(%Story{}, %Character{location_id: nil}, _locations, _text), do: :none

  def implied_departure(%Story{} = story, %Character{} = character, locations, text) do
    case candidates(character, locations, text) do
      [] -> :none
      candidates -> ask_departure(story, character, candidates, text)
    end
  end

  # The prefilter, and the reason this is affordable per beat. A place the
  # beat never names is not a place the beat sends anyone to. Matching is on
  # the whole name and on its longest word, so "The Kitchen" is found by
  # "into the kitchen" and "The Walled Garden" by "out to the garden" —
  # language-agnostic, because the names are the story's own.
  defp candidates(%Character{location_id: here}, locations, text) do
    haystack = String.downcase(text)

    for %Location{} = location <- locations,
        location.id != here,
        named?(haystack, location.name),
        do: location
  end

  defp named?(haystack, name) do
    name = String.downcase(name)

    String.contains?(haystack, name) or
      case name |> String.split(~r/\s+/u) |> Enum.max_by(&String.length/1, fn -> "" end) do
        word when byte_size(word) > 3 -> String.contains?(haystack, word)
        _short -> false
      end
  end

  defp ask_departure(story, character, candidates, text) do
    places = Enum.map_join(candidates, "\n", &"- #{&1.name}")

    request = %Request{
      model: LLM.character_model(),
      system: """
      You read one beat of an interactive story and decide whether
      #{character.name} moves themselves to another place IN THIS BEAT —
      actually going, arriving, leaving, or following someone there, not
      merely mentioning the place, looking toward it, or talking about going.

      The places #{character.name} could be moving to:
      #{places}

      Reply with exactly the name of the place #{character.name} moves to,
      and nothing else. If they stay where they are, reply with the single
      word NOTHING.
      """,
      messages: [%{role: :user, content: text}],
      max_tokens: 64
    }

    with {:ok, %{text: reply}} <- LLM.chat(request, story_id: story.id, purpose: :move_intent),
         answer = reply |> String.trim() |> String.trim_trailing("."),
         %Location{} = location <- AgenticStories.Stories.find_location(candidates, answer) do
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
      they left. Plain prose only, in the story's language — the language of
      the beats you are recapping.
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
