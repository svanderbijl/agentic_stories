defmodule AgenticStories.Engine.Weaver do
  @moduledoc """
  Turns a freeform seed into a live story: title, premise, arc, tone, style,
  opening narration, and a starting cast. Runs once per story, inside a
  supervised task started by `AgenticStories.Engine.seed_story/1`.
  """

  require Logger

  alias AgenticStories.Engine
  alias AgenticStories.Imagery
  alias AgenticStories.LLM
  alias AgenticStories.LLM.{JSON, Request}
  alias AgenticStories.Stories
  alias AgenticStories.Stories.Story

  @spec weave(Story.t()) :: {:ok, Story.t()} | {:error, term()}
  def weave(%Story{} = story) do
    request = %Request{
      model: LLM.weaver_model(),
      system: system_prompt(),
      messages: [%{role: :user, content: "Story seed:\n\n" <> story.seed}]
    }

    with {:ok, response} <- LLM.chat(request, story_id: story.id, purpose: :weave),
         {:ok, blueprint} <- parse_blueprint(response.text),
         {:ok, story} <- Stories.complete_weaving(story, blueprint) do
      paint_cast_and_opening(story, blueprint)
      {:ok, story}
    else
      error ->
        Logger.warning("weaving story #{story.id} failed: #{inspect(error)}")
        Stories.fail_weaving(story, describe_failure(error))
        {:error, error}
    end
  end

  # Portraits are painted best-effort in the background, concurrently; each
  # broadcasts a character_updated as it lands. A story is never worse off
  # for a failed portrait.
  #
  # The opening plate waits for them ON PURPOSE: it is composed from the
  # cast's portraits, and a plate that races them always wins the race and
  # always paints an empty room.
  defp paint_cast_and_opening(story, blueprint) do
    if Imagery.enabled?() do
      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        story.id
        |> Stories.list_characters()
        |> Task.async_stream(&paint_avatar(story, &1),
          max_concurrency: 4,
          timeout: 180_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        paint_opening_plate(story, blueprint)
      end)
    end

    :ok
  end

  defp paint_avatar(story, character) do
    case Imagery.generate(avatar_prompt(story, character)) do
      {:ok, %{binary: binary, content_type: content_type}} ->
        Stories.put_character_avatar(character, binary, content_type)

      {:error, reason} ->
        Logger.warning("no portrait for #{character.name}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.warning("no portrait for #{character.name}: #{Exception.message(exception)}")
  end

  # The opening scene earns the story's first establishing plate, painted
  # once the portraits are in so the cast is actually in the picture.
  defp paint_opening_plate(story, blueprint) do
    location =
      story.id
      |> Stories.list_locations()
      |> Enum.find(&(&1.id == story.player_location_id))

    if location do
      scene = "The story opens here. " <> String.slice(Map.fetch!(blueprint, :opening), 0, 500)
      Engine.commission_plate(story, location, location.name, scene)
    end

    :ok
  end

  @doc "The art direction for one character's portrait, kept coherent per story."
  def avatar_prompt(story, character) do
    looks =
      case character.appearance do
        nil -> ""
        appearance -> "How they look: #{appearance}\n"
      end

    """
    A photorealistic character portrait for a work of interactive fiction,
    shot like a film still: natural skin texture, soft directional light,
    shallow depth of field, head and shoulders, no text or lettering anywhere.

    The story's tone: #{story.tone}.
    The character: #{character.name} — #{character.persona}
    #{looks}
    """
  end

  @doc """
  Validates the model's JSON into an atom-keyed blueprint for
  `Stories.complete_weaving/2`. Lenient about extras, strict about essentials.
  """
  @spec parse_blueprint(String.t()) :: {:ok, map()} | :error
  def parse_blueprint(text) do
    with {:ok, map} <- JSON.decode_object(text),
         true <- Enum.all?(~w(title premise arc tone style opening), &filled?(map[&1])),
         [_ | _] = characters <- characters(map["characters"]),
         [_ | _] = locations <- locations(map["locations"]) do
      {:ok,
       %{
         title: map["title"],
         premise: map["premise"],
         arc: map["arc"],
         tone: map["tone"],
         style: map["style"],
         opening: map["opening"],
         opening_location: map["opening_location"],
         locations: locations,
         characters: characters
       }}
    else
      _ -> :error
    end
  end

  defp characters(list) when is_list(list) do
    for %{"name" => name, "persona" => persona} = attrs <- list,
        filled?(name) and filled?(persona) do
      %{
        name: name,
        persona: persona,
        voice: attrs["voice"],
        agenda: attrs["agenda"],
        arc: attrs["arc"],
        appearance: attrs["appearance"],
        location: attrs["location"],
        energy: Engine.config(:initial_energy)
      }
    end
  end

  defp characters(_), do: []

  defp locations(list) when is_list(list) do
    for %{"name" => name} = attrs <- list, filled?(name) do
      %{name: name, description: attrs["description"]}
    end
  end

  defp locations(_), do: []

  defp filled?(value), do: is_binary(value) and String.trim(value) != ""

  defp describe_failure({:error, _reason}), do: "the weave came apart mid-thread"
  defp describe_failure(:error), do: "the weave came back malformed"

  defp system_prompt do
    """
    You are the Weaver of an interactive fiction engine. A player gives you a
    freeform seed — a premise, a vibe, a fragment — and you design the story
    it wants to become. The player will then live inside it, writing to the
    world in second person; AI-driven characters will answer.

    Respond with exactly one JSON object and nothing else (no code fences,
    no commentary):

    {
      "title": "a short, evocative title",
      "premise": "one or two sentences of what this story is about",
      "arc": "one paragraph: how it opens, where the tension builds, and the shapes an ending might take — leave room for the player to bend it",
      "tone": "a few comma-separated words (e.g. 'wistful, dry-humored, quietly ominous')",
      "style": "prose style guidance the narrator and characters will follow",
      "locations": [
        {
          "name": "a short place name",
          "description": "what it is like to stand there, one or two sentences"
        }
      ],
      "opening_location": "the name of the location where the opening scene happens",
      "opening": "two to four short paragraphs of opening narration, written in the story's own style, addressed to 'you', ending at a moment that invites the player to speak or act",
      "characters": [
        {
          "name": "a name",
          "persona": "who they are and how they behave — two or three sentences the player may learn",
          "voice": "how they talk, in one sentence",
          "agenda": "what they privately want or hide — one or two sentences the player must NEVER be told directly",
          "arc": "this character's own journey across the story: where they start, what could change them, where they might end — one or two sentences",
          "appearance": "what they look like — build, face, hair, clothes — in one or two concrete sentences an illustrator could paint from",
          "location": "the name of the location where they are as the story opens"
        }
      ]
    }

    Give the story two to four locations implied by the seed — the world the
    player can move through. Give it two to four characters, each placed at
    one of those locations: at least one should be present at the opening
    scene, but someone elsewhere makes the world feel inhabited — the player
    only ever sees what happens where they are. Never cast the player. Honor
    the seed: keep its language, its ideas, and its implied genre, and
    amplify what makes it interesting.
    """
  end
end
