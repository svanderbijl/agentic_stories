defmodule AgenticStories.Engine.DirectorMind do
  @moduledoc """
  The Weaver at the loom after the story begins: an omniscient, low-frequency
  mind that supplies plot pressure. Unlike characters it sees every beat in
  every place, knows every agenda, and can narrate, nudge a character, open a
  new location, commission an illustration — or end the story.

  Pure apart from the `LLM.chat/2` call; the process half is
  `AgenticStories.Engine.DirectorAgent`.
  """

  require Logger

  alias AgenticStories.LLM
  alias AgenticStories.LLM.{JSON, Request}
  alias AgenticStories.Stories.{Character, Location, Message, Story}

  @type direction ::
          {:narrate, String.t(), String.t() | nil}
          | {:nudge, String.t(), String.t()}
          | {:reveal, String.t(), String.t()}
          | {:illustrate, String.t(), String.t()}
          | {:conclude, String.t()}
          | :wait

  @spec decide(Story.t(), [Character.t()], [Location.t()], [Message.t()]) :: direction
  def decide(%Story{} = story, characters, locations, beats) do
    request = %Request{
      model: LLM.director_model(),
      system: system_prompt(story, characters, locations),
      messages: [%{role: :user, content: tick_prompt(story, locations, beats)}],
      max_tokens: 2048
    }

    with {:ok, response} <- LLM.chat(request, story_id: story.id, purpose: :direct),
         {:ok, direction} <- parse_direction(response.text) do
      direction
    else
      _ -> :wait
    end
  rescue
    exception ->
      Logger.warning("the Director dozed off: #{Exception.message(exception)}")
      :wait
  end

  @spec parse_direction(String.t()) :: {:ok, direction()} | :error
  def parse_direction(text) do
    case JSON.decode_object(text) do
      {:ok, %{"do" => "narrate", "text" => narration} = map}
      when is_binary(narration) and narration != "" ->
        {:ok, {:narrate, narration, map["location"]}}

      {:ok, %{"do" => "nudge", "character" => name, "note" => note}}
      when is_binary(name) and name != "" and is_binary(note) and note != "" ->
        {:ok, {:nudge, name, note}}

      {:ok, %{"do" => "reveal", "name" => name, "description" => description}}
      when is_binary(name) and name != "" and is_binary(description) and description != "" ->
        {:ok, {:reveal, name, description}}

      {:ok, %{"do" => "illustrate", "prompt" => prompt, "caption" => caption}}
      when is_binary(prompt) and prompt != "" and is_binary(caption) and caption != "" ->
        {:ok, {:illustrate, prompt, caption}}

      {:ok, %{"do" => "conclude", "text" => closing}}
      when is_binary(closing) and closing != "" ->
        {:ok, {:conclude, closing}}

      {:ok, %{"do" => "wait"}} ->
        {:ok, :wait}

      _ ->
        :error
    end
  end

  @doc "The omniscient transcript: every beat, tagged with where it happened."
  @spec transcript([Message.t()], [Location.t()]) :: String.t()
  def transcript(beats, locations) do
    names = Map.new(locations, &{&1.id, &1.name})
    Enum.map_join(beats, "\n", &"#{place(&1, names)} #{line(&1)}")
  end

  defp place(%Message{location_id: nil}, _names), do: "[everywhere]"
  defp place(%Message{location_id: id}, names), do: "[#{Map.get(names, id, "?")}]"

  defp line(%Message{kind: :player, content: content}), do: "The player: #{content}"
  defp line(%Message{kind: :narration, content: content}), do: "Narrator: #{content}"
  defp line(%Message{kind: :illustration, content: content}), do: "(illustration: #{content})"
  defp line(%Message{kind: :say} = message), do: "#{speaker(message)}: #{message.content}"
  defp line(%Message{kind: :act} = message), do: "* #{speaker(message)} #{message.content}"
  # a future message kind must degrade, never blind the Director
  defp line(%Message{content: content}), do: "(#{content})"

  defp speaker(%Message{character: %Character{name: name}}), do: name
  defp speaker(%Message{}), do: "The player"

  defp system_prompt(story, characters, locations) do
    """
    You are the Director of a live work of interactive fiction, "#{story.title}".
    You see everything, everywhere; the player and the characters do not.

    Premise: #{story.premise}
    The arc you are steering toward: #{story.arc}
    Tone: #{story.tone}
    Style: #{story.style}

    The cast, with the private agendas only you and they know:
    #{cast(characters, locations)}
    The places:
    #{places(locations)}
    You will be shown the full record of the story, then asked whether to
    intervene. Reply with exactly one JSON object, nothing else:

    {"do": "narrate", "text": "one short paragraph of narration in the story's style", "location": "the exact name of the place it happens (omit for something felt everywhere)"}
    {"do": "nudge", "character": "exact name", "note": "a private impulse, in second person, that gives them a dramatic reason to act now"}
    {"do": "reveal", "name": "a new place's short name", "description": "what it is like to stand there"}
    {"do": "illustrate", "prompt": "a vivid visual description of the current scene for an illustrator", "caption": "a short caption in the story's voice"}
    {"do": "conclude", "text": "two or three closing paragraphs that resolve the arc, addressed to 'you'"}
    {"do": "wait"}

    Your principles:
    - Intervene rarely. The story belongs to the player and the cast; you supply
      pressure only when a scene stalls, drifts from the arc, or has earned a turn.
    - The one failure you must never allow: a player left hanging. If the player's
      latest beat has gone unanswered, motion is owed — nudge whoever should
      respond, or narrate the world responding.
    - Prefer "wait". Then prefer "nudge" (invisible) over "narrate" (visible).
    - Every character has their own arc. A scene that circles — banter without
      motion, questions without answers — is a scene to push: nudge someone
      toward the next step of THEIR story.
    - "reveal" a place only when the story has knocked on its door.
    - "illustrate" at most once in a great while, only for a genuinely striking moment.
    - "conclude" only when the arc has truly resolved and the scene is quiet.
      Ending a story is irreversible.
    - Never speak for a character and never address the player directly outside narration.
    """
  end

  defp cast(characters, locations) do
    names = Map.new(locations, &{&1.id, &1.name})

    Enum.map_join(characters, "\n", fn character ->
      where =
        case Map.get(names, character.location_id) do
          nil -> ""
          name -> " (at #{name})"
        end

      "- #{character.name}#{where}: #{character.persona}" <>
        if(character.agenda, do: " Privately: #{character.agenda}", else: "") <>
        if(character.arc, do: " Their arc: #{character.arc}", else: "")
    end)
  end

  defp places(locations) do
    Enum.map_join(locations, "\n", &"- #{&1.name}: #{&1.description}")
  end

  defp tick_prompt(story, locations, beats) do
    record =
      case beats do
        [] -> "Nothing has happened yet."
        beats -> transcript(beats, locations)
      end

    player_at =
      case Enum.find(locations, &(&1.id == story.player_location_id)) do
        nil -> ""
        location -> "The player is at: #{location.name}.\n"
      end

    """
    The record of the story so far, every place at once:

    #{record}

    #{player_at}#{stall_report(beats)}Does this moment need you? Reply with exactly one JSON object.
    """
  end

  # The signal the Director must not sleep through: the player moved the
  # story and nobody has moved it back.
  defp stall_report(beats) do
    unanswered =
      beats
      |> Enum.reverse()
      |> Enum.take_while(fn %Message{} = beat ->
        beat.kind == :player or (beat.kind == :act and is_nil(beat.character_id))
      end)
      |> length()

    if unanswered > 0 do
      "The player's last #{unanswered} beat(s) have gone unanswered by anyone.\n"
    else
      ""
    end
  end
end
