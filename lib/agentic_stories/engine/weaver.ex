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

  # Portraits and character-design sheets are painted best-effort in the
  # background, concurrently; each character broadcasts a character_updated
  # as they land. The player's likeness is painted here too — without it
  # every plate invents a new face for "you". A story is never worse off
  # for a failed portrait or sheet.
  #
  # The opening plate waits for them ON PURPOSE: it is composed from these
  # sheets, and a plate that races them always wins the race and always
  # paints strangers.
  defp paint_cast_and_opening(story, blueprint) do
    if Imagery.enabled?() do
      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        characters = Enum.map(Stories.list_characters(story.id), &{:character, &1})

        jobs =
          case story.protagonist do
            p when is_binary(p) and p != "" -> [{:player, story} | characters]
            _ -> characters
          end

        jobs
        |> Task.async_stream(&paint_subject(story, &1),
          max_concurrency: 4,
          timeout: 300_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        paint_opening_plate(story, blueprint)
      end)
    end

    :ok
  end

  defp paint_subject(story, {:player, _story}), do: Engine.paint_player_likeness(story)

  defp paint_subject(story, {:character, character}),
    do: Engine.paint_character_likeness(story, character)

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

  @doc "The art direction for the player's likeness, used as a plate reference and the You card."
  def player_avatar_prompt(%Story{} = story) do
    """
    A photorealistic character portrait for a work of interactive fiction,
    shot like a film still: natural skin texture, soft directional light,
    shallow depth of field, head and shoulders, no text or lettering anywhere.

    The story's tone: #{story.tone}.
    This is the player, whom the story addresses as "you": #{story.player_appearance || story.protagonist}
    """
  end

  # Venice's edit model (`qwen-edit-uncensored`) 400s a prompt over 1500
  # characters. The whole board prompt — looks, tone, and this layout —
  # has to fit. A long production brief is why sheets stopped landing.
  @sheet_layout """
  CHARACTER SHEET LAYOUT
  Wide landscape, studio-gray, photorealistic. New image: do not keep the source crop or background.

  Same person, every panel:
  - Full-body FRONT, 3/4, SIDE, BACK — head to feet, as described
  - Face close-ups: front, 3/4, profile
  Small labels: FRONT, 3/4, PROFILE, BACK, FACE.

  Dress exactly as the description says — clothes if it names them, undressed if it says so. If the reference is a head-and-shoulders crop, complete the body from the description.

  Same face, hair, proportions, colors. No redesign, extra limbs, watermarks, or logos.
  """

  @doc """
  Art direction for a character-design sheet composed from a portrait (or
  an earlier sheet). The attached image is identity; current appearance
  is what the sheet must be wearing now.
  """
  def board_prompt(story, character) do
    looks = character.appearance || character.persona

    """
    Using the attached image as the exact visual identity, paint a production character-design sheet for #{character.name}. Tone: #{story.tone}. How they look NOW: #{looks}. If the attached image shows earlier clothes, update clothes, hair, wounds, and accessories; keep the same face, body, and identity.

    #{@sheet_layout}
    """
  end

  @doc "Art direction for the player's character-design sheet."
  def player_board_prompt(%Story{} = story) do
    looks = story.player_appearance || story.protagonist

    """
    Using the attached image as the exact visual identity, paint a production character-design sheet for the same character. This is the player, whom the story addresses as "you": #{looks}. Tone: #{story.tone}. If the attached image shows earlier clothes, update clothes, hair, wounds, and accessories; keep the same face, body, and identity.

    #{@sheet_layout}
    """
  end

  @doc """
  A head-and-shoulders portrait taken from a character-design sheet, so the
  avatar stays true to the sheet after an appearance change.
  """
  def portrait_from_board_prompt(story, character) do
    looks = character.appearance || character.persona

    """
    Using the attached character reference sheet as the exact visual identity, paint a photorealistic character portrait of #{character.name} for a work of interactive fiction.

    Head and shoulders, front-facing, film still: natural skin texture, soft directional light, shallow depth of field. Use the sheet's front-facing face and how they look now. Single person. No character-sheet layout, no labels, no multiple views, no text or lettering anywhere.

    The story's tone: #{story.tone}.
    How they look: #{looks}
    """
  end

  @doc "A head-and-shoulders portrait of the player taken from their sheet."
  def player_portrait_from_board_prompt(%Story{} = story) do
    looks = story.player_appearance || story.protagonist

    """
    Using the attached character reference sheet as the exact visual identity, paint a photorealistic character portrait for a work of interactive fiction.

    Head and shoulders, front-facing, film still: natural skin texture, soft directional light, shallow depth of field. Use the sheet's front-facing face and how they look now. Single person. No character-sheet layout, no labels, no multiple views, no text or lettering anywhere.

    The story's tone: #{story.tone}.
    This is the player, whom the story addresses as "you": #{looks}
    """
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
         protagonist: optional(map["protagonist"]),
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
    for %{"name" => name, "persona" => persona, "appearance" => appearance} = attrs <- list,
        filled?(name) and filled?(persona) and filled?(appearance) do
      %{
        name: name,
        persona: persona,
        voice: attrs["voice"],
        agenda: attrs["agenda"],
        arc: attrs["arc"],
        appearance: appearance,
        entrance: attrs["entrance"],
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

  defp optional(value), do: if(filled?(value), do: value, else: nil)

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
      "protagonist": "who the PLAYER is in this story, in the third person, as the cast would see them: name (the one the seed gives them, or one that fits), what they are doing here, and what they look like — one or two sentences. If the seed describes the player's looks, copy them; do not invent a different face or dress",
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
          "appearance": "what they look like — build, face, hair, clothes — in one or two concrete sentences an illustrator could paint from. If the seed describes how they look, copy that exactly; do not invent a different face, build, or dress. Invent looks only when the seed is silent about them",
          "location": "the name of the location where they are as the story opens"
        }
      ]
    }

    The opening narration is written to the player as "you". Every character
    who appears in it reads it as part of their own memory, and cannot tell
    which person in it is themselves unless you say so — that is what
    "entrance" is for, and a character in the opening scene without one will
    assume the player's role. For the same reason "protagonist" is never
    optional: read the seed for who the player says they are and name them.
    If the seed does not say, invent someone spare who fits, and make sure
    the opening narration and each entrance agree with what you wrote.

    Give the story two to four locations implied by the seed — the world the
    player can move through. Give it two to four characters, each placed at
    one of those locations: at least one should be present at the opening
    scene, but someone elsewhere makes the world feel inhabited — the player
    only ever sees what happens where they are. Never cast the player as a
    character — "protagonist" describes them, it does not add them to the
    cast. Honor the seed: keep its language, its ideas, its implied genre,
    and any physical description it gives — a red dress in the seed is a
    red dress in the story. Amplify what makes it interesting.
    """
  end
end
