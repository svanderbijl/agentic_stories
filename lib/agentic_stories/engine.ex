defmodule AgenticStories.Engine do
  @moduledoc """
  The story runtime: weaves seeds into stories and runs one agent process
  per character. There is deliberately no global tick — each character
  schedules its own, and energy decides whether it fires.

  This module is the public API for the web layer.
  """

  require Logger

  alias AgenticStories.Engine.{CharacterAgent, DirectorAgent, Narrator, Presence, Weaver}
  alias AgenticStories.Imagery
  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Character, Location, Story}

  @doc """
  Creates a story in `:weaving` state and weaves it in a supervised task.
  Returns the story immediately; progress arrives over PubSub.
  """
  @spec seed_story(String.t()) :: {:ok, Story.t()} | {:error, Ecto.Changeset.t()}
  def seed_story(seed) do
    with {:ok, story} <- Stories.create_story(%{seed: seed}) do
      {:ok, _pid} =
        Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
          weave_or_fail(story)
        end)

      {:ok, story}
    end
  end

  # A crash inside the weave (a raised misconfiguration, a driver bug) must
  # never leave the story stuck on "weaving" — mark it frayed, then let the
  # crash surface in the logs.
  defp weave_or_fail(story) do
    Weaver.weave(story)
  rescue
    exception ->
      Stories.fail_weaving(story, "the loom jammed: " <> Exception.message(exception))
      reraise exception, __STACKTRACE__
  end

  @doc "Idempotently starts the character agents and the Director for a live story."
  @spec ensure_running(Story.t()) :: :ok
  def ensure_running(%Story{status: :live} = story) do
    if config(:start_agents) do
      story.id
      |> Stories.list_characters()
      |> Enum.each(&start_child({CharacterAgent, character: &1, story: story}))

      start_child({DirectorAgent, story: story})
    end

    :ok
  end

  def ensure_running(%Story{}), do: :ok

  defp start_child(spec) do
    case DynamicSupervisor.start_child(AgenticStories.Engine.CharacterSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Records a player message where the player stands and energizes the cast:
  characters in the same place get the full charge, everyone else an ambient
  trickle — enough to occasionally live their own lives off-screen. Also
  revives retired agents first — a returning player brings the cast back.
  """
  @spec player_message(Story.t(), String.t()) ::
          {:ok, Stories.Message.t()} | {:error, Ecto.Changeset.t()}
  def player_message(%Story{} = story, content) do
    {kind, content} = parse_player_input(content)
    attrs = %{kind: kind, content: content, location_id: story.player_location_id}

    with {:ok, message} <- Stories.create_message(story, attrs) do
      # the sentence has landed; the floor is the cast's again
      Presence.stopped_typing(story.id)
      ensure_running(story)
      energize_cast(story)
      follow_narrated_move(story, content)
      {:ok, message}
    end
  end

  # "You head for the porch…" must actually take the player to the porch:
  # a beat that narrates movement executes it (arrival narration, residue,
  # establishing plate, and a fresh charge for whoever is there), a breath
  # after the beat itself lands.
  defp follow_narrated_move(%Story{} = story, content) do
    locations = Stories.list_locations(story.id)

    if length(locations) >= 2 do
      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        with {:ok, location} <- Narrator.implied_move(story, locations, content),
             # re-read: the world may have moved while we were reading intent
             %Story{status: :live} = story <- Stories.get_story!(story.id),
             true <- location.id != story.player_location_id do
          player_move(story, location.id)
        end
      end)
    end

    :ok
  end

  # `*I douse the lamp*` is a deed, not a line: it becomes an act beat
  # (character_id nil marks it as the player's).
  defp parse_player_input(content) do
    trimmed = String.trim(content || "")

    case Regex.run(~r/\A\*+\s*(.+?)\s*\**\z/s, trimmed) do
      [_full, action] -> {:act, action}
      nil -> {:player, content}
    end
  end

  defp energize_cast(%Story{} = story) do
    for character <- Stories.list_characters(story.id) do
      if co_located?(character, story) do
        CharacterAgent.energize(character.id, config(:player_energy), :player)
      else
        CharacterAgent.energize(character.id, config(:ambient_energy), :ambient)
      end
    end

    DirectorAgent.energize(story.id, config(:player_energy))
    :ok
  end

  defp co_located?(%Character{location_id: where}, %Story{player_location_id: player}) do
    is_nil(where) or is_nil(player) or where == player
  end

  @doc """
  The player is writing. Until they send (or `typing_grace_ms` passes), the
  cast and the Director yield the floor: a tick that lands during a draft
  costs nothing and simply comes back around, and a line drafted before the
  player started typing is held rather than spoken over them.
  """
  @spec player_typing(Story.t()) :: :ok
  def player_typing(%Story{status: :live} = story), do: Presence.typing(story.id)
  def player_typing(%Story{}), do: :ok

  @doc "The draft was sent or cleared: the cast may speak again immediately."
  @spec player_stopped_typing(Story.t()) :: :ok
  def player_stopped_typing(%Story{} = story), do: Presence.stopped_typing(story.id)

  @doc """
  Records a character's utterance (`:say`) or action (`:act`) where they
  stand and passes the torch: chatter energy goes to ONE other cast member
  in the same place (the next in cast order), so exchanges happen but always
  decay — a beat grants less energy than the tick that produced it.
  """
  def character_message(%Story{} = story, %Character{} = character, kind, content)
      when kind in [:say, :act] do
    attrs = %{
      kind: kind,
      content: content,
      character_id: character.id,
      location_id: character.location_id
    }

    with {:ok, message} <- Stories.create_message(story, attrs) do
      pass_the_torch(story.id, character)
      {:ok, message}
    end
  end

  @doc """
  Moves a character: one beat, witnessed at both the origin and the
  destination, then the relocation itself.
  """
  def character_move(%Story{} = story, %Character{} = character, %Location{} = location, text) do
    attrs = %{
      kind: :act,
      content: text,
      character_id: character.id,
      location_id: location.id,
      witness_location_ids: [character.location_id, location.id]
    }

    with {:ok, message} <- Stories.create_message(story, attrs),
         {:ok, character} <- Stories.relocate_character(character, location.id) do
      {:ok, message, character}
    end
  end

  @doc """
  Moves the player to another of the story's places: a narration beat
  witnessed at both ends, then a fresh charge for whoever is at the
  destination — walking into a room is interaction too.
  """
  def player_move(%Story{} = story, location_id) do
    location = Stories.get_location!(story.id, location_id)
    origin_id = story.player_location_id

    if location.id == origin_id do
      {:ok, story}
    else
      missed = Stories.missed_beats(story.id, location.id)

      with {:ok, story} <- Stories.move_player(story, location.id),
           {:ok, _message} <-
             Stories.create_message(story, %{
               kind: :narration,
               content: "You make your way to #{location.name}.",
               location_id: location.id,
               witness_location_ids: [origin_id, location.id]
             }) do
        narrate_residue(story, location, missed)

        # every place earns one establishing plate, on first arrival
        unless Stories.plate_at?(story.id, location.id) do
          commission_plate(
            story,
            location,
            location.name,
            "An establishing view of #{location.name}. #{location.description}"
          )
        end

        ensure_running(story)
        energize_cast(story)
        {:ok, story}
      end
    end
  end

  # What you find when you arrive somewhere things happened without you:
  # traces, generated in the background so the move itself stays instant.
  defp narrate_residue(_story, _location, []), do: :ok

  defp narrate_residue(%Story{} = story, %Location{} = location, missed) do
    Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
      with {:ok, text} <- Narrator.residue(story, location, missed) do
        Stories.create_message(story, %{
          kind: :narration,
          content: text,
          location_id: location.id
        })
      end
    end)

    :ok
  end

  @doc """
  The Director calls the ending: a closing narration everyone witnesses,
  the story becomes `:finished`, and the cast retires for good.
  """
  def finish_story(%Story{} = story, closing) do
    with {:ok, _message} <- Stories.create_message(story, %{kind: :narration, content: closing}),
         {:ok, story} <- Stories.finish_story(story) do
      retire_story_agents(story.id)
      # an ending is the biggest turn a story takes: it earns a last plate
      commission_plate(story, player_location(story), "The end", closing)
      {:ok, story}
    end
  end

  @doc "The player closes the book themselves: a quiet ending, then rest."
  def end_story(%Story{status: :live} = story) do
    finish_story(story, "Here you close the book, and the story rests.")
  end

  def end_story(%Story{} = story), do: {:ok, story}

  @doc """
  Deletes a story outright: agents first (so nothing writes mid-deletion),
  then the story and everything it owns, then its ledger rows.
  """
  def delete_story(%Story{} = story) do
    retire_story_agents(story.id)

    with {:ok, story} <- Stories.delete_story(story) do
      AgenticStories.LLM.Ledger.forget(story.id)
      {:ok, story}
    end
  end

  # :shutdown reads as a deliberate stop to any supervisor (transient agents
  # are not restarted), wherever the agent happens to be supervised. The
  # caller's own process is skipped — the Director concludes from inside
  # finish_story and stops itself afterwards.
  defp retire_story_agents(story_id) do
    character_pids =
      for character <- Stories.list_characters(story_id),
          pid = CharacterAgent.whereis(character.id),
          is_pid(pid),
          do: pid

    pids =
      case DirectorAgent.whereis(story_id) do
        nil -> character_pids
        pid -> [pid | character_pids]
      end

    for pid <- pids, pid != self(), do: Process.exit(pid, :shutdown)
    :ok
  end

  @doc """
  Applies a Director decision (except `conclude`, which the DirectorAgent
  routes through `finish_story/2` so it can retire itself afterwards).
  """
  def apply_direction(%Story{} = story, direction, characters, locations) do
    case direction do
      {:narrate, text, location_name} ->
        location = Stories.find_location(locations, location_name)

        with {:ok, _message} <-
               Stories.create_message(story, %{
                 kind: :narration,
                 content: text,
                 location_id: location && location.id
               }) do
          # narration is stimulus: whoever hears it may react
          for character <- characters,
              is_nil(location) or character.location_id == location.id do
            CharacterAgent.energize(character.id, config(:chatter_energy), :chatter)
          end

          :ok
        end

      {:nudge, character_name, note} ->
        case Enum.find(characters, &(&1.name == character_name)) do
          nil -> :ok
          character -> CharacterAgent.nudge(character.id, note, config(:director_grant))
        end

      {:reveal, name, description} ->
        case Stories.create_location(story, %{name: name, description: description}) do
          {:ok, location} ->
            Logger.info("the Director reveals #{location.name}")
            :ok

          {:error, _changeset} ->
            :ok
        end

      {:illustrate, prompt, caption} ->
        # The prompt invites plates at real turning points; this is what keeps
        # a run of them (and the bill) in check. Code-side on purpose — the
        # Director cannot count beats, and asking it to would only cost tokens.
        if Stories.beats_since_plate(story.id) >= config(:plate_cooldown_beats) do
          location =
            story.player_location_id && Enum.find(locations, &(&1.id == story.player_location_id))

          commission_plate(story, location, caption, prompt)
        else
          Logger.debug("plate for \"#{story.title}\" skipped — the last one is still fresh")
          :ok
        end

      :wait ->
        :ok
    end
  end

  @doc """
  The player asks for a picture of where they are. Unlike every other plate,
  this one is not commissioned from a caller who already knows the scene: the
  Narrator reads the story back first and works out who is present, how they
  are standing, what they are wearing by now, and what the place looks like.

  Runs in the background — the read-back and the render both take a while —
  and answers over PubSub like any other beat. The Director's plate cooldown
  does not apply: the player asked.
  """
  @spec request_plate(Story.t()) :: :ok
  def request_plate(%Story{status: :live} = story) do
    if Imagery.enabled?() do
      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        location = player_location(story)
        # no locations at all (a legacy or frayed story) reads as "everyone
        # is here", the same degradation path witnessing uses
        present =
          case location do
            nil -> Stories.list_characters(story.id)
            location -> present_characters(story, location)
          end

        beats = story.id |> Stories.player_messages() |> Enum.take(-config(:memory_window))

        case Narrator.tableau(story, location, present, beats) do
          {:ok, scene, caption} -> paint_plate(story, location, caption, scene, present)
          :none -> Logger.warning("no tableau for \"#{story.title}\"; picture skipped")
        end
      end)
    end

    :ok
  end

  def request_plate(%Story{}), do: :ok

  @doc """
  Paints a scene plate in the background: present characters' portraits ride
  along as reference images (up to three) so the people in the plate are the
  people on the cast cards; if composition fails, a text-only render still
  lands. Best-effort — a story is never worse off for a missing plate.
  """
  def commission_plate(%Story{} = story, location, caption, scene) do
    if Imagery.enabled?() do
      present = present_characters(story, location)

      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        paint_plate(story, location, caption, scene, present)
      end)
    end

    :ok
  end

  defp paint_plate(story, location, caption, scene, present) do
    portraits = portraits(present)

    result =
      case portraits do
        [] ->
          Imagery.generate(plate_art_direction(story, location, scene, present))

        portraits ->
          cast = Enum.map(portraits, &elem(&1, 0))
          references = Enum.map(portraits, &elem(&1, 1))

          case Imagery.compose(plate_composition(story, location, scene, cast), references) do
            {:ok, image} ->
              {:ok, image}

            {:error, reason} ->
              # Say why. A silent fallback here is exactly how a bad edit
              # model or a rejected payload hides for weeks as the vague
              # complaint "the plates never have anyone in them".
              Logger.warning("no composition for \"#{story.title}\": #{inspect(reason)}")
              Imagery.generate(plate_art_direction(story, location, scene, present))
          end
      end

    case result do
      {:ok, %{binary: binary, content_type: content_type}} ->
        Stories.create_message(story, %{
          kind: :illustration,
          content: caption,
          location_id: location && location.id,
          image: binary,
          image_type: content_type
        })

      {:error, reason} ->
        Logger.warning("no plate for \"#{story.title}\": #{inspect(reason)}")
    end
  end

  # The characters whose portraits can ride along as reference images, paired
  # with the images themselves — capped at the three the port accepts, in
  # cast order, so the names in the prompt line up with the source images.
  defp portraits(present) do
    present
    |> Enum.filter(& &1.avatar_type)
    |> Enum.take(3)
    |> Enum.flat_map(fn character ->
      case Stories.get_avatar(character.id) do
        {binary, content_type} -> [{character, %{binary: binary, content_type: content_type}}]
        nil -> []
      end
    end)
  end

  # Words only. The cast leads: an art direction that opens with camera talk
  # and buries the people at the bottom gets back an empty room.
  defp plate_art_direction(story, location, scene, present) do
    """
    #{cast_clause(present)}#{place_clause(location)}What is happening: #{scene}

    Paint it as a photorealistic film still for a work of interactive fiction:
    the people above clearly visible in frame, natural light, shallow depth of
    field, no text or lettering anywhere. The story's tone: #{story.tone}.
    """
  end

  # With reference portraits this is an EDIT, not a fresh render: the first
  # source image is the base the model works from, so name the people in the
  # order their portraits were sent and ask for a new scene around them.
  defp plate_composition(story, location, scene, cast) do
    people =
      cast
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {character, index} ->
        "- source image #{index}: #{character.name}"
      end)

    """
    Compose the people from the source images into one new photorealistic
    scene together — same faces, same builds, unmistakably these people:

    #{people}

    #{place_clause(location)}What is happening: #{scene}

    Full-length framing that shows them in the place, shot like a film still:
    natural light, no text or lettering anywhere. The story's tone: #{story.tone}.
    """
  end

  defp place_clause(nil), do: ""
  defp place_clause(location), do: "Where: #{location.name} — #{location.description}\n"

  defp cast_clause([]), do: ""

  defp cast_clause(present) do
    lines =
      Enum.map_join(present, "\n", fn character ->
        "- #{character.name}: #{character.appearance || character.persona}"
      end)

    "Who is in frame:\n#{lines}\n"
  end

  defp player_location(%Story{player_location_id: nil}), do: nil

  defp player_location(%Story{} = story) do
    story.id
    |> Stories.list_locations()
    |> Enum.find(&(&1.id == story.player_location_id))
  end

  defp present_characters(_story, nil), do: []

  defp present_characters(%Story{} = story, location) do
    story.id
    |> Stories.list_characters()
    |> Enum.filter(&(&1.location_id == location.id))
  end

  defp pass_the_torch(story_id, %Character{} = speaker) do
    listeners =
      story_id
      |> Stories.list_characters()
      |> Enum.reject(&(&1.id == speaker.id))
      |> Enum.filter(&same_place?(&1, speaker))

    case Enum.find(listeners, List.first(listeners), &(&1.id > speaker.id)) do
      nil -> :ok
      next -> CharacterAgent.energize(next.id, config(:chatter_energy), :chatter)
    end
  end

  defp same_place?(%Character{location_id: a}, %Character{location_id: b}) do
    is_nil(a) or is_nil(b) or a == b
  end

  @doc "Reads a value from the engine configuration."
  def config(key) do
    :agentic_stories
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
