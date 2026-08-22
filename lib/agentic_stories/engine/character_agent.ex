defmodule AgenticStories.Engine.CharacterAgent do
  @moduledoc """
  One process per character. Ticks on its own schedule (with jitter, so the
  cast never moves in lockstep): each tick spends energy and asks the
  character's mind whether to say something, do something, or wait. Out of
  energy, the agent goes dormant — no scheduled tick at all — until player
  interaction energizes it awake.

  Two clocks bound a scene without a player:

    * energy — chatter grants less than a tick costs, so the cast strictly
      drains and generation decays to silence on its own;
    * the idle deadline — `idle_timeout_ms` after the last *player* message
      (or after starting), the agent retires: it stops normally, energy or
      not, and `Engine.ensure_running/1` revives it on the next visit.

  The LLM call blocks the agent during its own tick. That is intentional:
  it serializes one character's behaviour without slowing anyone else down.
  """

  use GenServer, restart: :transient

  require Logger

  alias AgenticStories.Engine
  alias AgenticStories.Engine.CharacterMind
  alias AgenticStories.Engine.Presence
  alias AgenticStories.Stories

  ## Client

  def start_link(opts) do
    character = Keyword.fetch!(opts, :character)
    GenServer.start_link(__MODULE__, opts, name: via(character.id))
  end

  @doc """
  Grants energy (capped). The source decides the tempo:

    * `:player` — the player is right here talking: the next tick is pulled
      forward to the wake delay so the character answers promptly.
    * `:ambient` — the player is active somewhere else: refreshes the idle
      deadline and wakes a dormant agent, but lazily, at the full cadence.
    * `:chatter` — the torch from another character: wakes a dormant agent
      at the wake delay, never extends the idle deadline.
  """
  def energize(character_id, amount, source) when source in [:player, :ambient, :chatter] do
    GenServer.cast(via(character_id), {:energize, amount, source})
  end

  @doc """
  A whisper from the Director: grants energy, stores a private one-tick
  impulse, and pulls the next tick forward. Does not extend the idle
  deadline — only a human keeps a story alive.
  """
  def nudge(character_id, note, amount) do
    GenServer.cast(via(character_id), {:nudge, note, amount})
  end

  def whereis(character_id) do
    case Registry.lookup(AgenticStories.Engine.Registry, {:character, character_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via(character_id) do
    {:via, Registry, {AgenticStories.Engine.Registry, {:character, character_id}}}
  end

  ## Server

  @impl true
  def init(opts) do
    # trapped so terminate/2 always runs — a dying agent must never leave a
    # stuck "about to…" quill on the cast panel
    Process.flag(:trap_exit, true)

    character = Keyword.fetch!(opts, :character)
    story = Keyword.get_lazy(opts, :story, fn -> Stories.get_story!(character.story_id) end)

    state = %{
      story: story,
      character: character,
      energy: character.energy,
      dormant?: false,
      tick_timer: nil,
      idle_deadline: fresh_deadline()
    }

    Process.send_after(self(), :retire, Engine.config(:idle_timeout_ms))

    # The first tick runs at the full cadence, not the wake delay: the
    # opening scene gets a beat of air before anyone reacts to it.
    {:ok, schedule_tick(state, tick_delay())}
  end

  @impl true
  def handle_cast({:energize, amount, source}, state) do
    energy = min(state.energy + amount, Engine.config(:max_energy))
    state = persist_energy(%{state | energy: energy})

    state =
      if source in [:player, :ambient],
        do: %{state | idle_deadline: fresh_deadline()},
        else: state

    state =
      cond do
        energy < Engine.config(:tick_cost) ->
          state

        # spoken to directly: answer promptly, whatever was scheduled
        source == :player ->
          schedule_tick(%{state | dormant?: false}, wake_delay())

        state.dormant? and source == :ambient ->
          schedule_tick(%{state | dormant?: false}, tick_delay())

        state.dormant? ->
          schedule_tick(%{state | dormant?: false}, wake_delay())

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_cast({:nudge, note, amount}, state) do
    energy = min(state.energy + amount, Engine.config(:max_energy))
    state = persist_energy(%{state | energy: energy})
    state = %{state | character: %{state.character | nudge: note}}

    if energy >= Engine.config(:tick_cost) do
      {:noreply, schedule_tick(%{state | dormant?: false}, wake_delay())}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    cond do
      # the player is writing: the floor is theirs. Yield without spending —
      # a held tick costs nothing and comes back around in a couple of seconds.
      Presence.typing?(state.story.id) ->
        {:noreply, schedule_tick(state, wake_delay())}

      state.energy >= Engine.config(:tick_cost) ->
        state = persist_energy(%{state | energy: state.energy - Engine.config(:tick_cost)})
        {state, next_delay} = state |> consolidate_memory() |> take_turn()
        {:noreply, schedule_tick(state, next_delay)}

      true ->
        {:noreply, %{state | dormant?: true, tick_timer: nil}}
    end
  end

  # An exit signal (finish/delete retiring the cast) becomes a message under
  # trap_exit; stop with the given reason so transient supervision agrees.
  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(:retire, state) do
    remaining = state.idle_deadline - now_ms()

    if remaining <= 0 do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :retire, remaining)
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Stories.signal_thinking(state.story.id, state.character.id, false)
    :ok
  end

  # When witnessed beats fall out of the working window, fold them into the
  # character's long-term memory first — through their own lens. This happens
  # at chunk boundaries, exactly when the prompt-cache prefix breaks anyway.
  defp consolidate_memory(%{story: story, character: character} = state) do
    with {:fade, beats, new_count} <-
           Stories.fading_beats(character, Engine.config(:memory_window)),
         memories = Stories.list_memories(character),
         {:ok, entry} <- CharacterMind.consolidate(story, character, memories, beats),
         {:ok, character} <- Stories.append_character_memory(character, entry, new_count) do
      %{state | character: character}
    else
      _ -> state
    end
  end

  defp take_turn(%{story: story, character: character} = state) do
    # fetched fresh each tick: the Director can open new places mid-story
    locations = Stories.list_locations(story.id)
    memories = Stories.list_memories(character)
    messages = Stories.character_memory(character, Engine.config(:memory_window))
    alone? = alone_with_player?(story, character)

    Stories.signal_thinking(story.id, character.id, true)

    decision =
      CharacterMind.decide(story, character, memories, messages, locations,
        alone_with_player?: alone?
      )

    Stories.signal_thinking(story.id, character.id, false)

    # a nudge lasts exactly one tick
    state = %{state | character: %{state.character | nudge: nil}}

    {state, delay, answered?} =
      case decision do
        {:say, text} ->
          attempt(state, :say, text, messages)

        {:act, text} ->
          attempt(state, :act, text, messages)

        {:move, destination, text} ->
          {move(state, locations, destination, text), tick_delay(), true}

        :wait ->
          {state, tick_delay(), false}
      end

    # A directly-addressed character owes an answer. Whatever went wrong —
    # a chosen wait, a collision, a dropped repeat — they try again at the
    # wake delay until they have actually responded. Energy bounds the loop.
    if not answered? and CharacterMind.directly_addressed?(character, messages, alone?) do
      {state, wake_delay()}
    else
      {state, delay}
    end
  end

  # Is the player here, with no other character present? Then everything
  # they say is to this character.
  defp alone_with_player?(%{id: story_id}, character) do
    player_location = Stories.player_location_id(story_id)

    here? =
      is_nil(player_location) or is_nil(character.location_id) or
        player_location == character.location_id

    here? and
      not Enum.any?(Stories.list_characters(story_id), fn other ->
        other.id != character.id and
          (is_nil(other.location_id) or other.location_id == character.location_id)
      end)
  end

  # Post-decision guards. A collision (the conversation moved, or the player
  # started typing, while this character was thinking) holds the line but
  # retries at the wake delay — they still have something to say. A
  # repetition is just dropped.
  defp attempt(%{story: story, character: character} = state, kind, text, messages) do
    case verdict(character, text, messages) do
      :ok ->
        Engine.character_message(story, character, kind, text)
        {state, tick_delay(), true}

      :collision ->
        Logger.debug("#{character.name} held their tongue — the conversation moved")
        {state, wake_delay(), false}

      :repetition ->
        Logger.debug("#{character.name} almost repeated themselves")
        {state, tick_delay(), false}

      :monologue ->
        Logger.debug("#{character.name} would have followed themselves — the floor is not theirs")
        {state, tick_delay(), false}
    end
  end

  defp verdict(character, text, messages) do
    snapshot =
      case List.last(messages) do
        nil -> 0
        last -> last.id
      end

    cond do
      # they started typing while this line was being thought up: same as
      # any other collision — hold it, come back when the player has spoken.
      Presence.typing?(character.story_id) -> :collision
      following_themselves?(character, messages) -> :monologue
      conversation_moved?(character, snapshot) -> :collision
      CharacterMind.repetitive?(character, text, messages) -> :repetition
      true -> :ok
    end
  end

  # A player message funds three ticks, so a character with something to say
  # will happily say it three times in a row — which reads as one person
  # talking to themselves, not as a scene. One beat each, then the floor goes
  # back: they may follow the player, another character, or the Director, but
  # never their own last word. Moves are exempt (they leave through their own
  # path), so walking out on your own line still works.
  defp following_themselves?(character, messages) do
    case List.last(messages) do
      %Stories.Message{kind: kind, character_id: id} when kind in [:say, :act] ->
        id == character.id

      _ ->
        false
    end
  end

  # Only DIALOGUE makes a drafted line stale: the player spoke again, or
  # another character got there first. Background acts, narration, and
  # plates never cancel speech — a busy room must not starve its talkers.
  defp conversation_moved?(character, snapshot) do
    character
    |> Stories.witnessed_after(snapshot)
    |> Enum.any?(fn beat ->
      beat.kind == :player or
        (beat.kind in [:say, :act] and is_nil(beat.character_id)) or
        (beat.kind == :say and beat.character_id != character.id)
    end)
  end

  defp move(%{story: story, character: character} = state, locations, name, text) do
    case Stories.find_location(locations, name) do
      nil ->
        state

      %{id: id} when id == character.location_id ->
        state

      location ->
        text =
          if is_binary(text) and String.trim(text) != "",
            do: text,
            else: "slips away toward #{location.name}"

        case Engine.character_move(story, character, location, text) do
          {:ok, _message, character} -> %{state | character: character}
          {:error, _reason} -> state
        end
    end
  end

  defp persist_energy(%{character: character, energy: energy} = state) do
    case Stories.update_character_energy(character, energy) do
      {:ok, character} -> %{state | character: character}
      {:error, _changeset} -> state
    end
  end

  # One pending tick at a time: rescheduling cancels the previous timer, so
  # hastening never piles extra ticks up.
  defp schedule_tick(state, delay) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    %{state | tick_timer: Process.send_after(self(), :tick, delay)}
  end

  defp fresh_deadline, do: now_ms() + Engine.config(:idle_timeout_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp tick_delay do
    jitter(Engine.config(:tick_interval_ms))
  end

  # Waking (on energize) reacts much faster than the tick cadence, so
  # characters answer the player promptly.
  defp wake_delay do
    jitter(div(Engine.config(:tick_interval_ms), 8))
  end

  defp jitter(base) when base > 0, do: base + :rand.uniform(max(div(base, 2), 1))
end
