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
    summon_addressed(story, content)
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
             true <- location.id != story.player_location_id,
             {:ok, story} <- player_move(story, location.id) do
          # "Maren, let's walk down to the shore" gathered her BEFORE the
          # words landed — and then the walk left her standing in the room
          # the player just abandoned, permanently elsewhere. Whoever the
          # beat named comes along.
          summon_addressed(story, content, "follows you to #{location.name}")
        end
      end)
    end

    :ok
  end

  # The player is the camera: if they are talking to someone, that someone is
  # in the scene. A character named in the player's words who has wandered
  # elsewhere is pulled back BEFORE the words land — through the same visible
  # beat-and-relocation path as any move — so they witness the summons and
  # answer it, instead of the world arguing with the fiction. Whole-name,
  # word-bounded: "Art" must not be conjured by "a fresh start".
  defp summon_addressed(story, content, narration \\ "finds their way back to you")

  defp summon_addressed(%Story{player_location_id: nil}, _content, _narration), do: :ok

  defp summon_addressed(%Story{} = story, content, narration) do
    for character <- Stories.list_characters(story.id),
        character.location_id != nil,
        character.location_id != story.player_location_id,
        Regex.match?(~r/\b#{Regex.escape(character.name)}\b/iu, content) do
      location = Stories.get_location!(story.id, story.player_location_id)

      case character_move(story, character, location, narration) do
        {:ok, _message, moved} -> CharacterAgent.relocated(moved.id, moved.location_id)
        {:error, _reason} -> :ok
      end
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
  destination, then the relocation itself. `kind` keeps a beat that both
  speaks and leaves ("Maren follows him down, "You shouldn't be out here"")
  a `:say`, so it still passes the torch and still reads as dialogue.
  """
  def character_move(
        %Story{} = story,
        %Character{} = character,
        %Location{} = location,
        text,
        kind \\ :act
      ) do
    attrs = %{
      kind: kind,
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
  def player_move(%Story{} = story, location_id, narration \\ nil) do
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
               content: narration || "You make your way to #{location.name}.",
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
            String.trim("An establishing view of #{location.name}. #{location.description}")
          )
        end

        ensure_running(story)
        energize_cast(story)
        {:ok, story}
      end
    end
  end

  @doc """
  The player goes looking for a character instead of a place: a move to
  wherever they are right now. The UI never names the destination — you
  learn where someone went by finding them, in the arrival narration.
  A character who is already with the player (or nowhere) is a no-op.
  """
  def player_seek(%Story{} = story, character_id) do
    character = Stories.get_character!(character_id)

    case character.location_id do
      nil ->
        {:ok, story}

      location_id ->
        location = Stories.get_location!(story.id, location_id)

        player_move(
          story,
          location_id,
          "You go looking for #{character.name}, and find them at #{location.name}."
        )
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
        # A model happily re-"reveals" a place the story already has, and a
        # second row with the same name splits witnessing across twin rooms.
        # An existing place only ever gains the description it was missing.
        case Stories.find_location(locations, name) do
          %Location{} = location ->
            Stories.describe_location(location, description)
            :ok

          nil ->
            case Stories.create_location(story, %{name: name, description: description}) do
              {:ok, location} ->
                Logger.info("the Director reveals #{location.name}")
                :ok

              {:error, _changeset} ->
                :ok
            end
        end

      {:move_character, character_name, location_name, text} ->
        move_cast_member(story, characters, locations, character_name, location_name, text)

      {:looks, character_name, appearance, text} ->
        dress_cast_member(story, characters, character_name, appearance, text)

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

  # The Director relocates a cast member: the same beat-and-relocation path a
  # character's own move takes, so witnessing and the world stay honest — a
  # narrated return that moved nobody is how "she is back but still elsewhere"
  # happens. A live agent is told, or it would keep acting from the old room.
  defp move_cast_member(story, characters, locations, character_name, location_name, text) do
    with %Character{} = character <- Enum.find(characters, &(&1.name == character_name)),
         %Location{} = location <-
           Stories.find_location(locations, location_name) ||
             open_directed_location(story, location_name),
         true <- location.id != character.location_id do
      text =
        if is_binary(text) and String.trim(text) != "",
          do: text,
          else: "makes their way to #{location.name}"

      case character_move(story, character, location, text) do
        {:ok, _message, character} ->
          Logger.info("the Director moves #{character.name} to #{location.name}")
          CharacterAgent.relocated(character.id, character.location_id)
          :ok

        {:error, _reason} ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp open_directed_location(story, name) do
    case Stories.create_location(story, %{name: name}) do
      {:ok, location} -> location
      {:error, _changeset} -> nil
    end
  end

  # The Director changes how someone looks: persist it, tell a live agent so
  # they stop writing from the old clothes, and rebuild the character sheet
  # (and from it the portrait) so the next plate's face-lock is not still
  # wearing the weave. An optional beat makes the change visible in the
  # record the way a directed move is.
  defp dress_cast_member(story, characters, character_name, appearance, text) do
    appearance = appearance |> to_string() |> String.trim()

    with true <- appearance != "",
         %Character{} = character <- Enum.find(characters, &(&1.name == character_name)),
         {:ok, character} <- Stories.describe_character(character, appearance) do
      Logger.info("the Director looks at #{character.name}")
      CharacterAgent.redressed(character.id, character.appearance)
      refresh_likeness_later(story, character)
      write_looks_beat(story, character, text)
      :ok
    else
      _ -> :ok
    end
  end

  defp write_looks_beat(story, character, text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        :ok

      content ->
        Stories.create_message(story, %{
          kind: :act,
          content: content,
          character_id: character.id,
          location_id: character.location_id
        })

        :ok
    end
  end

  defp write_looks_beat(_story, _character, _text), do: :ok

  # A plate that actually saw how people look NOW writes it down. Characters
  # are told not to re-describe clothing, so the record will not say it
  # again; without this the next plate falls back to the woven clothes.
  defp remember_looks(story, present, looks) when looks in [nil, []], do: {story, present}

  defp remember_looks(story, present, looks) do
    Enum.each(looks, fn {name, appearance} ->
      try do
        remember_one(story, present, name, appearance)
      rescue
        exception ->
          Logger.warning("could not remember looks for #{name}: #{Exception.message(exception)}")
      end
    end)

    {Stories.get_story!(story.id), Enum.map(present, &Stories.get_character!(&1.id))}
  end

  defp remember_one(_story, _present, _name, appearance)
       when appearance in [nil, ""],
       do: :ok

  defp remember_one(story, present, name, appearance) do
    appearance = appearance |> to_string() |> String.trim()
    if appearance == "", do: :ok, else: remember_trimmed(story, present, name, appearance)
  end

  defp remember_trimmed(story, present, name, appearance) do
    case match_looks_subject(present, name) do
      :player ->
        unless same_looks?(story.player_appearance || story.protagonist, appearance) do
          {:ok, story} = Stories.describe_player(story, appearance)
          refresh_player_likeness(story)
        end

      %Character{id: id} ->
        character = Stories.get_character!(id)

        unless same_looks?(character.appearance, appearance) do
          case Stories.describe_character(character, appearance) do
            {:ok, updated} ->
              CharacterAgent.redressed(updated.id, updated.appearance)
              refresh_character_likeness(story, updated)

            {:error, _reason} ->
              :ok
          end
        end

      nil ->
        :ok
    end
  end

  defp match_looks_subject(present, name) do
    key = name |> to_string() |> String.trim() |> String.downcase()

    cond do
      key in ["the player", "player", "you"] ->
        :player

      character = Enum.find(present, &(String.downcase(&1.name) == key)) ->
        character

      true ->
        nil
    end
  end

  defp same_looks?(left, right), do: String.trim(left || "") == String.trim(right || "")

  defp refresh_likeness_later(story, character) do
    if Imagery.enabled?() do
      Task.Supervisor.start_child(AgenticStories.Engine.TaskSupervisor, fn ->
        refresh_character_likeness(story, character)
      end)
    end

    :ok
  end

  @doc """
  First likeness for a character: a portrait, then a character-design sheet
  composed from it. If the portrait already exists, just the missing sheet.
  Best-effort — a failed sheet leaves the portrait and the story fine.
  """
  def paint_character_likeness(story, character) do
    if Imagery.enabled?() do
      cond do
        Stories.get_board(character.id) ->
          :ok

        Stories.get_avatar(character.id) ->
          paint_character_board(story, character)

        true ->
          seed_character_likeness(story, character)
      end
    end

    :ok
  rescue
    exception ->
      Logger.warning("no likeness for #{character.name}: #{Exception.message(exception)}")
      :ok
  end

  @doc """
  First likeness for the player: a portrait, then a character-design sheet.
  Same skip rules as `paint_character_likeness/2`.
  """
  def paint_player_likeness(%Story{protagonist: protagonist} = story)
      when is_binary(protagonist) and protagonist != "" do
    if Imagery.enabled?() do
      cond do
        Stories.get_player_board(story.id) ->
          :ok

        Stories.get_player_avatar(story.id) ->
          paint_player_board(story)

        true ->
          seed_player_likeness(story)
      end
    end

    :ok
  rescue
    exception ->
      Logger.warning("no likeness for the player: #{Exception.message(exception)}")
      :ok
  end

  def paint_player_likeness(_story), do: :ok

  @doc """
  Appearance changed: rebuild the sheet from the current identity (sheet
  if we have one, otherwise the portrait) so the face stays put, then a
  new portrait from that sheet so the avatar is wearing the new clothes.
  In-process so a plate compose that follows sees the new likeness.
  """
  def refresh_character_likeness(story, character) do
    if Imagery.enabled?() do
      case identity_reference(Stories.get_board(character.id), Stories.get_avatar(character.id)) do
        nil ->
          seed_character_likeness(story, character)

        reference ->
          case compose_image(Weaver.board_prompt(story, character), [reference], character.name) do
            {:ok, board} ->
              Stories.put_character_board(character, board.binary, board.content_type)

              case compose_image(
                     Weaver.portrait_from_board_prompt(story, character),
                     [board],
                     character.name
                   ) do
                {:ok, portrait} ->
                  Stories.put_character_avatar(character, portrait.binary, portrait.content_type)

                :error ->
                  :ok
              end

            :error ->
              :ok
          end
      end
    end

    :ok
  rescue
    exception ->
      Logger.warning("no likeness for #{character.name}: #{Exception.message(exception)}")
      :ok
  end

  @doc "Appearance changed for the player: same rebuild as a cast member."
  def refresh_player_likeness(%Story{} = story) do
    if Imagery.enabled?() do
      case identity_reference(
             Stories.get_player_board(story.id),
             Stories.get_player_avatar(story.id)
           ) do
        nil ->
          seed_player_likeness(story)

        reference ->
          case compose_image(Weaver.player_board_prompt(story), [reference], "the player") do
            {:ok, board} ->
              Stories.put_player_board(story, board.binary, board.content_type)

              case compose_image(
                     Weaver.player_portrait_from_board_prompt(story),
                     [board],
                     "the player"
                   ) do
                {:ok, portrait} ->
                  Stories.put_player_avatar(story, portrait.binary, portrait.content_type)

                :error ->
                  :ok
              end

            :error ->
              :ok
          end
      end
    end

    :ok
  rescue
    exception ->
      Logger.warning("no likeness for the player: #{Exception.message(exception)}")
      :ok
  end

  defp seed_character_likeness(story, character) do
    case Imagery.generate(Weaver.avatar_prompt(story, character)) do
      {:ok, %{binary: binary, content_type: content_type} = portrait} ->
        Stories.put_character_avatar(character, binary, content_type)
        paint_character_board(story, character, portrait)

      {:error, reason} ->
        Logger.warning("no portrait for #{character.name}: #{inspect(reason)}")
    end
  end

  defp seed_player_likeness(story) do
    case Imagery.generate(Weaver.player_avatar_prompt(story)) do
      {:ok, %{binary: binary, content_type: content_type} = portrait} ->
        Stories.put_player_avatar(story, binary, content_type)
        paint_player_board(story, portrait)

      {:error, reason} ->
        Logger.warning("no portrait for the player: #{inspect(reason)}")
    end
  end

  defp paint_character_board(story, character, portrait \\ nil) do
    reference = portrait || image(Stories.get_avatar(character.id))

    if reference do
      case compose_image(Weaver.board_prompt(story, character), [reference], character.name) do
        {:ok, board} ->
          Stories.put_character_board(character, board.binary, board.content_type)

        :error ->
          :ok
      end
    end
  end

  defp paint_player_board(story, portrait \\ nil) do
    reference = portrait || image(Stories.get_player_avatar(story.id))

    if reference do
      case compose_image(Weaver.player_board_prompt(story), [reference], "the player") do
        {:ok, board} ->
          Stories.put_player_board(story, board.binary, board.content_type)

        :error ->
          :ok
      end
    end
  end

  defp compose_image(prompt, references, who) do
    case Imagery.compose(prompt, references) do
      {:ok, image} ->
        {:ok, image}

      {:error, reason} ->
        Logger.warning("no likeness compose for #{who}: #{inspect(reason)}")
        :error
    end
  end

  defp identity_reference(board, portrait) do
    case {board, portrait} do
      {nil, nil} -> nil
      {board, _} when not is_nil(board) -> image(board)
      {_, portrait} -> image(portrait)
    end
  end

  defp image(nil), do: nil
  defp image({binary, content_type}), do: %{binary: binary, content_type: content_type}
  defp image(%{binary: _, content_type: _} = image), do: image

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
          {:ok, scene, caption, looks} ->
            paint_plate(story, location, caption, scene, present, looks)

          :none ->
            Logger.warning("no tableau for \"#{story.title}\"; picture skipped")
        end
      end)
    end

    :ok
  end

  def request_plate(%Story{}), do: :ok

  @doc """
  Paints a scene plate in the background: present characters' sheets ride
  along as reference images (up to three) so the people in the plate are
  the people on the cast cards. A sheet is the identity document — face,
  body, clothes — and a portrait is the fallback when no sheet exists yet.
  Venice's multi-edit treats the first image as the canvas: that slot has
  to be a person (sheet or portrait), never a generated scene of invented
  extras. If composition fails, a text-only render still lands. Best-effort
  — a story is never worse off for a missing plate.
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

  defp paint_plate(story, location, caption, scene, present, looks \\ []) do
    {story, present} = remember_looks(story, present, looks)
    portraits = portraits(story, present)

    result =
      case portraits do
        [] ->
          Imagery.generate(plate_art_direction(story, location, scene, present))

        portraits ->
          subjects = Enum.map(portraits, &elem(&1, 0))
          references = Enum.map(portraits, &elem(&1, 1))

          case Imagery.compose(plate_composition(story, location, scene, subjects), references) do
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

  # Likeness references for compose, capped at the three the port accepts.
  # Prefer the character sheet (full identity) over the headshot. The player
  # leads when they have one: they are in every picture, and without that
  # face each plate invents a new "you". Then present characters, in cast
  # order, so names line up with source images. Image 1 is the canvas: it
  # must be a person, never a generated scene of invented extras (that is
  # how two plates of the same story grow two casts).
  defp portraits(story, present) do
    (player_portrait(story) ++ character_portraits(present))
    |> Enum.take(3)
  end

  defp player_portrait(%Story{} = story) do
    case player_likeness(story) do
      {binary, content_type} ->
        [
          {%{name: "the player", appearance: current_player_looks(story)},
           %{binary: binary, content_type: content_type}}
        ]

      nil ->
        []
    end
  end

  # New weaves paint this up front. A story woven before player likeness
  # existed still gets one on the next plate, so "you" stop changing face.
  # The sheet is the identity document; the portrait is the fallback.
  defp player_likeness(%Story{id: id, protagonist: protagonist} = story)
       when is_binary(protagonist) and protagonist != "" do
    case Stories.get_player_board(id) || Stories.get_player_avatar(id) do
      {binary, content_type} ->
        {binary, content_type}

      nil ->
        paint_player_likeness(story)
        Stories.get_player_board(id) || Stories.get_player_avatar(id)
    end
  end

  defp player_likeness(_story), do: nil

  defp character_portraits(present) do
    present
    |> Enum.filter(&(&1.board_type || &1.avatar_type))
    |> Enum.flat_map(fn character ->
      case Stories.get_board(character.id) || Stories.get_avatar(character.id) do
        {binary, content_type} ->
          [
            {%{name: character.name, appearance: character.appearance},
             %{binary: binary, content_type: content_type}}
          ]

        nil ->
          []
      end
    end)
  end

  # Words only. The cast leads: an art direction that opens with camera talk
  # and buries the people at the bottom gets back an empty room. Looks on
  # the character are current; the scene still wins if the record is newer.
  defp plate_art_direction(story, location, scene, present) do
    """
    #{cast_clause(story, present)}#{place_clause(location)}What is happening: #{scene}

    Paint it as a photorealistic candid film still, caught mid-action: the
    people above clearly visible in frame, full-length, natural light,
    shallow depth of field, no text or lettering anywhere. Nobody looks at
    the camera — they look at each other or at what they are doing. The
    story's tone: #{story.tone}. Faces, hair, and builds match the
    descriptions; clothing, pose, and expression are what the scene says
    they are, even when that disagrees with the descriptions above.
    """
  end

  # With reference sheets this is an EDIT whose first source image is the
  # canvas. Name the people in the order their sheets were sent. Likeness
  # comes from the FRONT VIEW on those sheets; clothing, pose, and crop
  # come from the scene — otherwise every plate is a restaged character
  # board, four views of the same person in a gray studio.
  defp plate_composition(story, location, scene, subjects) do
    people =
      subjects
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {subject, index} ->
        case subject.appearance do
          nil -> "- source image #{index}: #{subject.name}"
          appearance -> "- source image #{index}: #{subject.name} — #{appearance}"
        end
      end)

    named_player? = Enum.any?(subjects, &(&1.name == "the player"))
    player_note = if named_player?, do: "", else: player_line(story) <> "\n"

    """
    Compose the people from the source images into one new photorealistic
    scene together — same faces, same builds, unmistakably these people.
    Each source image is a character reference sheet (or a portrait if no
    sheet exists). It gives likeness only: use the FRONT VIEW of that
    person for face, body, hair, and how they look now. Do not copy the
    sheet's layout, labels, multiple views, gray studio background, crop,
    camera, pose, or gaze. Do not put more than one copy of the same
    person in the frame. Paint a new full-length candid film still, caught
    mid-action. Nobody looks at the camera — they look at each other or at
    what they are doing, as the scene describes. Clothing, posture, and
    expression are what the scene below says they are, even when that
    disagrees with the sheet or the original dress.

    #{people}

    #{player_note}#{place_clause(location)}What is happening: #{scene}

    Natural light, no text or lettering anywhere. The story's tone: #{story.tone}.
    """
  end

  defp place_clause(nil), do: ""
  defp place_clause(location), do: "Where: #{location.name} — #{location.description}\n"

  defp cast_clause(story, present) do
    lines =
      [
        player_line(story)
        | Enum.map(present, fn character ->
            "- #{character.name}: #{character.appearance || character.persona}"
          end)
      ]
      |> Enum.join("\n")

    """
    Who is in frame (face, hair, and build as described; clothing is whatever the scene below says):
    #{lines}
    """
  end

  defp player_line(%Story{} = story) do
    case current_player_looks(story) do
      nil -> "- the player"
      looks -> "- the player: #{looks}"
    end
  end

  defp current_player_looks(%Story{} = story),
    do: story.player_appearance || story.protagonist

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
