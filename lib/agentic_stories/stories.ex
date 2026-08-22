defmodule AgenticStories.Stories do
  @moduledoc """
  Persistence context for stories, their cast, and the message log.

  Every change is broadcast over PubSub — to `"stories"` (all lifecycle
  events) and `"story:\#{id}"` (that story's events) — as
  `{:story_updated, story}`, `{:message_created, message}`, or
  `{:character_updated, character}`. No LLM calls or process orchestration
  belong here; that's `AgenticStories.Engine`.
  """

  import Ecto.Query, warn: false

  alias AgenticStories.Repo

  alias AgenticStories.Stories.{
    Character,
    CharacterMemory,
    Location,
    Message,
    MessageWitness,
    Story
  }

  @pubsub AgenticStories.PubSub

  ## PubSub

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "stories")
  def subscribe(story_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(story_id))

  defp topic(story_id), do: "story:#{story_id}"

  defp broadcast(story_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, "stories", event)
    Phoenix.PubSub.broadcast(@pubsub, topic(story_id), event)
  end

  ## Stories

  def list_stories do
    Repo.all(from s in Story, order_by: [desc: s.id])
  end

  def get_story!(id), do: Repo.get!(Story, id)

  @doc "Creates a story in `:weaving` state from a player's seed."
  def create_story(attrs) do
    %Story{}
    |> Story.seed_changeset(attrs)
    |> Repo.insert()
    |> broadcast_story()
  end

  @doc """
  Applies a Weaver blueprint in one transaction: the story goes `:live`, its
  places are created, the cast is placed in them, the player starts at the
  opening location, and the opening narration becomes the first message —
  witnessed by whoever is there. Blueprints without locations degrade to a
  location-less story where every beat is witnessed by everyone.
  """
  def complete_weaving(%Story{} = story, blueprint) do
    story_attrs = Map.take(blueprint, [:title, :premise, :arc, :tone, :style])

    Ecto.Multi.new()
    |> Ecto.Multi.update(:story, Story.weave_changeset(story, story_attrs))
    |> insert_locations(Map.get(blueprint, :locations, []))
    |> Ecto.Multi.run(:locations, fn _repo, changes ->
      {:ok, collect_indexed(changes, :location)}
    end)
    |> Ecto.Multi.run(:opening_location, fn _repo, %{locations: locations} ->
      opening = find_location(locations, Map.get(blueprint, :opening_location))
      {:ok, opening || List.first(locations)}
    end)
    |> Ecto.Multi.run(:placed_story, fn repo, %{story: story, opening_location: opening} ->
      story
      |> Ecto.Changeset.change(player_location_id: opening && opening.id)
      |> repo.update()
    end)
    |> insert_characters(Map.get(blueprint, :characters, []))
    |> Ecto.Multi.insert(:opening, fn %{story: story, opening_location: opening} ->
      %Message{story_id: story.id}
      |> Message.changeset(%{
        kind: :narration,
        content: Map.fetch!(blueprint, :opening),
        location_id: opening && opening.id,
        witnessed_by_player: true
      })
    end)
    |> Ecto.Multi.run(:opening_witnesses, fn repo, %{opening: opening} = changes ->
      rows =
        for character <- collect_indexed(changes, :character),
            is_nil(opening.location_id) or character.location_id == opening.location_id do
          %{message_id: opening.id, character_id: character.id}
        end

      repo.insert_all(MessageWitness, rows)
      {:ok, length(rows)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{placed_story: story}} ->
        broadcast_story({:ok, story})

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp insert_locations(multi, locations) do
    locations
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {attrs, index}, multi ->
      Ecto.Multi.insert(multi, {:location, index}, fn %{story: story} ->
        Location.changeset(%Location{story_id: story.id}, attrs)
      end)
    end)
  end

  defp insert_characters(multi, characters) do
    characters
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {attrs, index}, multi ->
      Ecto.Multi.insert(multi, {:character, index}, fn changes ->
        %{story: story, locations: locations, opening_location: opening} = changes
        {location_name, attrs} = Map.pop(attrs, :location)
        location = find_location(locations, location_name) || opening

        Character.changeset(
          %Character{story_id: story.id, location_id: location && location.id},
          attrs
        )
      end)
    end)
  end

  defp collect_indexed(changes, tag) do
    changes
    |> Enum.filter(&match?({{^tag, _index}, _value}, &1))
    |> Enum.sort_by(fn {{_tag, index}, _value} -> index end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  @doc "Finds a location by (case-insensitive) name in a list of locations."
  def find_location(_locations, nil), do: nil

  def find_location(locations, name) do
    target = name |> to_string() |> String.trim() |> String.downcase()
    Enum.find(locations, &(String.downcase(&1.name) == target))
  end

  def fail_weaving(%Story{} = story, reason) do
    story
    |> Story.failure_changeset(reason)
    |> Repo.update()
    |> broadcast_story()
  end

  @doc """
  Boot-time reaper: a story still `:weaving` when the application starts was
  orphaned by a restart mid-weave — its task is gone and it would stay on the
  loom forever. Fray it so the player sees an honest state.
  """
  def fray_orphaned_weaves do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(from(s in Story, where: s.status == :weaving),
        set: [status: "failed", failure_reason: "the loom went cold mid-weave", updated_at: now]
      )

    count
  end

  @doc "The story has resolved: it becomes a finished book on the shelf."
  def finish_story(%Story{} = story) do
    story
    |> Story.finish_changeset()
    |> Repo.update()
    |> broadcast_story()
  end

  @doc """
  Deletes a story and everything it owns (locations, cast, beats, witnesses
  cascade at the database level). Broadcasts `{:story_deleted, story}` so
  open pages can leave gracefully.
  """
  def delete_story(%Story{} = story) do
    case Repo.delete(story) do
      {:ok, story} ->
        broadcast(story.id, {:story_deleted, story})
        {:ok, story}

      error ->
        error
    end
  end

  defp broadcast_story({:ok, %Story{} = story}) do
    broadcast(story.id, {:story_updated, story})
    {:ok, story}
  end

  defp broadcast_story({:error, _} = error), do: error

  ## Characters

  def list_characters(story_id) do
    Repo.all(from c in Character, where: c.story_id == ^story_id, order_by: [asc: c.id])
  end

  def get_character!(id), do: Repo.get!(Character, id)

  def update_character_energy(%Character{} = character, energy) do
    character
    |> Character.changeset(%{energy: energy})
    |> Repo.update()
    |> broadcast_character()
  end

  def put_character_avatar(%Character{} = character, binary, content_type) do
    character
    |> Character.avatar_changeset(binary, content_type)
    |> Repo.update()
    |> broadcast_character()
  end

  @doc "The avatar image for a character, or nil — the binary is loaded only here."
  def get_avatar(character_id) do
    query =
      from c in Character,
        where: c.id == ^character_id and not is_nil(c.avatar_type),
        select: {c.avatar, c.avatar_type}

    Repo.one(query)
  end

  # Reload before broadcasting: callers usually update from a struct loaded
  # earlier (an agent's copy from before the portrait was painted), and Ecto
  # returns the changeset's data, not the row — broadcasting the stale copy
  # would erase concurrently-updated fields (the avatar) from every
  # subscriber's view. The reload also leaves out the image binary
  # (load_in_query: false), so broadcasts stay light.
  defp broadcast_character({:ok, %Character{} = character}) do
    character = Repo.reload!(character)
    broadcast(character.story_id, {:character_updated, character})
    {:ok, character}
  end

  defp broadcast_character({:error, _} = error), do: error

  ## Messages & witnessing

  @doc """
  Creates a beat and records who witnessed it, permanently. `attrs` may carry
  `:location_id` (where it happens) and `:witness_location_ids` (every place
  it is perceptible from — e.g. both ends of a move). Characters at those
  locations get witness rows; the player's presence is stamped on the row
  itself. A nil location (legacy or location-less stories) means everyone
  witnesses.
  """
  def create_message(%Story{} = story, attrs) do
    {witness_location_ids, attrs} = Map.pop(attrs, :witness_location_ids)
    location_ids = witness_location_ids || [Map.get(attrs, :location_id)]
    global? = Enum.any?(location_ids, &is_nil/1)

    # The player's location is read fresh, never trusted from the caller's
    # struct: agents hold stories loaded at start-up, and a player who moved
    # rooms since must still witness what happens around them NOW.
    player_location_id = player_location_id(story.id)

    witnessed_by_player? =
      global? or is_nil(player_location_id) or player_location_id in location_ids

    changeset =
      %Message{story_id: story.id}
      |> Message.changeset(Map.put(attrs, :witnessed_by_player, witnessed_by_player?))

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:message, changeset)
    |> Ecto.Multi.run(:witnesses, fn repo, %{message: message} ->
      rows =
        for id <- witness_character_ids(repo, story.id, global?, location_ids) do
          %{message_id: message.id, character_id: id}
        end

      repo.insert_all(MessageWitness, rows)
      {:ok, length(rows)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        message = Repo.preload(message, :character)
        broadcast(story.id, {:message_created, message})
        {:ok, message}

      {:error, :message, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp witness_character_ids(repo, story_id, true = _global?, _location_ids) do
    repo.all(from c in Character, where: c.story_id == ^story_id, select: c.id)
  end

  defp witness_character_ids(repo, story_id, false, location_ids) do
    # nil-located characters in a located story would otherwise witness
    # nothing at all; count them as present everywhere
    repo.all(
      from c in Character,
        where: c.story_id == ^story_id,
        where: c.location_id in ^location_ids or is_nil(c.location_id),
        select: c.id
    )
  end

  @doc "Everything the player has witnessed, in story order — the reading pane."
  def player_messages(story_id) do
    Repo.all(
      from m in Message,
        where: m.story_id == ^story_id and m.witnessed_by_player == true,
        order_by: [asc: m.id],
        preload: :character
    )
  end

  @doc "The last `limit` beats regardless of witnesses — the Director's omniscient view."
  def recent_beats(story_id, limit) do
    Repo.all(
      from m in Message,
        where: m.story_id == ^story_id,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: :character
    )
    |> Enum.reverse()
  end

  @doc "Every beat of the story regardless of witnesses (tooling and tests)."
  def list_messages(story_id) do
    Repo.all(
      from m in Message,
        where: m.story_id == ^story_id,
        order_by: [asc: m.id],
        preload: :character
    )
  end

  @doc """
  A character's working memory: the recent beats *they witnessed*, in story
  order, trimmed in `window`-sized chunks rather than one by one. Two
  invariants protect it:

    * chunked trims keep the list a stable prefix between trims — sliding it
      per message would change the transcript's head every tick and defeat
      LLM prompt caching;
    * nothing is trimmed until it has been folded into long-term memory
      (`memory_beats`) — a failed consolidation never punches a hole in what
      the character knows, and the trim lands exactly when the memory (and
      so the cached system prompt) changes anyway.
  """
  def character_memory(%Character{} = character, window) do
    drop = min(chunk_drop(witnessed_count(character), window), character.memory_beats)

    character
    |> witnessed_query()
    |> offset(^drop)
    |> Repo.all()
  end

  @doc """
  Witnessed beats that have slipped out of the character's working window but
  are not yet folded into long-term memory. Returns `{:fade, beats,
  new_memory_beats}` to consolidate, or `:none`.
  """
  def fading_beats(%Character{} = character, window) do
    drop = chunk_drop(witnessed_count(character), window)

    if drop > character.memory_beats do
      beats =
        character
        |> witnessed_query()
        |> offset(^character.memory_beats)
        |> limit(^(drop - character.memory_beats))
        |> Repo.all()

      {:fade, beats, drop}
    else
      :none
    end
  end

  @doc """
  Appends one immutable memory block and advances the consolidated watermark
  in the same transaction. Blocks are never rewritten — the chain stays a
  byte-stable prompt prefix and early memories never degrade.
  """
  def append_character_memory(%Character{} = character, content, memory_beats) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:memory, %CharacterMemory{character_id: character.id, content: content})
    |> Ecto.Multi.update(:character, Ecto.Changeset.change(character, memory_beats: memory_beats))
    |> Repo.transaction()
    |> case do
      {:ok, %{character: character}} -> broadcast_character({:ok, character})
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "A character's memory blocks, oldest first."
  def list_memories(%Character{} = character) do
    Repo.all(
      from m in CharacterMemory,
        where: m.character_id == ^character.id,
        order_by: [asc: m.id]
    )
  end

  defp witnessed_query(%Character{} = character) do
    from m in Message,
      left_join: w in MessageWitness,
      on: w.message_id == m.id and w.character_id == ^character.id,
      where: m.story_id == ^character.story_id,
      where: not is_nil(w.character_id) or is_nil(m.location_id),
      order_by: [asc: m.id],
      preload: :character
  end

  defp witnessed_count(%Character{} = character) do
    character
    |> witnessed_query()
    |> exclude(:order_by)
    |> exclude(:preload)
    |> Repo.aggregate(:count)
  end

  defp chunk_drop(total, window), do: div(max(total - window, 0), window) * window

  ## Locations & movement

  def list_locations(story_id) do
    Repo.all(from l in Location, where: l.story_id == ^story_id, order_by: [asc: l.id])
  end

  @doc "A new place opens mid-story (the Director earns it into existence)."
  def create_location(%Story{} = story, attrs) do
    %Location{story_id: story.id}
    |> Location.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, location} ->
        broadcast(story.id, {:location_created, location})
        {:ok, location}

      error ->
        error
    end
  end

  def get_location!(story_id, id) do
    Repo.one!(from l in Location, where: l.story_id == ^story_id and l.id == ^id)
  end

  def relocate_character(%Character{} = character, location_id) do
    character
    |> Ecto.Changeset.change(location_id: location_id)
    |> Repo.update()
    |> broadcast_character()
  end

  def move_player(%Story{} = story, location_id) do
    story
    |> Ecto.Changeset.change(player_location_id: location_id)
    |> Repo.update()
    |> broadcast_story()
  end

  @doc "The player's location as it is RIGHT NOW — never trust a cached struct."
  def player_location_id(story_id) do
    Repo.one(from s in Story, where: s.id == ^story_id, select: s.player_location_id)
  end

  ## Residue, collisions & signals

  @doc """
  Beats at a location the player missed since they last witnessed something
  there — the raw material for residue narration on arrival. The residue
  beat itself is witnessed at that location, so it advances the watermark
  and the same events are never summarized twice.
  """
  def missed_beats(story_id, location_id) do
    watermark =
      Repo.one(
        from m in Message,
          where:
            m.story_id == ^story_id and m.location_id == ^location_id and
              m.witnessed_by_player == true,
          select: max(m.id)
      ) || 0

    Repo.all(
      from m in Message,
        where:
          m.story_id == ^story_id and m.location_id == ^location_id and
            m.witnessed_by_player == false and m.id > ^watermark,
        order_by: [asc: m.id],
        preload: :character
    )
  end

  @doc "Beats this character witnessed after a watermark — the collision check."
  def witnessed_after(%Character{} = character, message_id) do
    character
    |> witnessed_query()
    |> where([m], m.id > ^message_id)
    |> Repo.all()
  end

  @doc """
  Transient presence cue: a character is thinking (their LLM call is in
  flight). Broadcast-only — nothing is persisted.
  """
  def signal_thinking(story_id, character_id, thinking?) do
    broadcast(story_id, {:character_thinking, character_id, thinking?})
  end

  @doc "Whether a location already has an establishing plate — one per place, ever."
  def plate_at?(story_id, location_id) do
    Repo.exists?(
      from m in Message,
        where:
          m.story_id == ^story_id and m.location_id == ^location_id and
            m.kind == :illustration
    )
  end

  @doc """
  How many beats have landed since the last plate — the cooldown that keeps
  the Director from illustrating a story to death. A story that has never
  been illustrated is unbounded (`:infinity`), so the first plate is free.
  """
  def beats_since_plate(story_id) do
    last =
      Repo.one(
        from m in Message,
          where: m.story_id == ^story_id and m.kind == :illustration,
          select: max(m.id)
      )

    case last do
      nil ->
        :infinity

      last ->
        Repo.one(
          from m in Message,
            where: m.story_id == ^story_id and m.id > ^last,
            select: count(m.id)
        )
    end
  end

  @doc "The plate image for an illustration beat, or nil."
  def get_illustration(message_id) do
    Repo.one(
      from m in Message,
        where: m.id == ^message_id and m.kind == :illustration and not is_nil(m.image_type),
        select: {m.image, m.image_type}
    )
  end
end
