defmodule AgenticStories.Engine.DirectorAgent do
  @moduledoc """
  One per live story: the process half of the Director. Runs on the same
  energy/tick discipline as the cast — there is still no global tick — but
  slower (`director_interval_ms`), funded only by player activity, and
  retired by the same idle deadline. Its energy is deliberately in-memory:
  a restarted Director starts fresh with `director_energy`.
  """

  use GenServer, restart: :transient

  require Logger

  alias AgenticStories.Engine
  alias AgenticStories.Engine.DirectorMind
  alias AgenticStories.Stories

  ## Client

  def start_link(opts) do
    story = Keyword.fetch!(opts, :story)
    GenServer.start_link(__MODULE__, opts, name: via(story.id))
  end

  @doc "Player activity funds the Director like it funds the cast."
  def energize(story_id, amount) do
    GenServer.cast(via(story_id), {:energize, amount})
  end

  def whereis(story_id) do
    case Registry.lookup(AgenticStories.Engine.Registry, {:director, story_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via(story_id) do
    {:via, Registry, {AgenticStories.Engine.Registry, {:director, story_id}}}
  end

  ## Server

  @impl true
  def init(opts) do
    story = Keyword.fetch!(opts, :story)

    state = %{
      story: story,
      energy: Engine.config(:director_energy),
      dormant?: false,
      tick_timer: nil,
      idle_deadline: now_ms() + Engine.config(:idle_timeout_ms)
    }

    Process.send_after(self(), :retire, Engine.config(:idle_timeout_ms))
    {:ok, schedule_tick(state, tick_delay())}
  end

  @impl true
  def handle_cast({:energize, amount}, state) do
    energy = min(state.energy + amount, Engine.config(:max_energy))
    state = %{state | energy: energy, idle_deadline: now_ms() + Engine.config(:idle_timeout_ms)}

    # Player activity pulls the next look forward — far enough out that the
    # cast gets first right of reply, close enough that a scene nobody
    # answers stalls for half a minute, not ninety seconds. Never pushed
    # back: an already-sooner tick stands.
    if energy >= Engine.config(:tick_cost) do
      attentive = attentive_delay()

      cond do
        state.dormant? ->
          {:noreply, schedule_tick(%{state | dormant?: false}, attentive)}

        state.tick_timer && remaining(state.tick_timer) > attentive ->
          {:noreply, schedule_tick(state, attentive)}

        true ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    story = Stories.get_story!(state.story.id)

    cond do
      story.status != :live ->
        {:stop, :normal, state}

      state.energy >= Engine.config(:tick_cost) ->
        state = %{state | story: story, energy: state.energy - Engine.config(:tick_cost)}

        case direct(story) do
          :concluded -> {:stop, :normal, state}
          :ok -> {:noreply, schedule_tick(state, tick_delay())}
        end

      true ->
        {:noreply, %{state | dormant?: true, tick_timer: nil}}
    end
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

  defp direct(story) do
    characters = Stories.list_characters(story.id)
    locations = Stories.list_locations(story.id)
    beats = Stories.recent_beats(story.id, 2 * Engine.config(:memory_window))

    case DirectorMind.decide(story, characters, locations, beats) do
      {:conclude, closing} ->
        Logger.info("the Director closes \"#{story.title}\"")
        Engine.finish_story(story, closing)
        :concluded

      direction ->
        Engine.apply_direction(story, direction, characters, locations)
        :ok
    end
  end

  defp schedule_tick(state, delay) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    %{state | tick_timer: Process.send_after(self(), :tick, delay)}
  end

  defp tick_delay do
    base = Engine.config(:director_interval_ms)
    base + :rand.uniform(max(div(base, 2), 1))
  end

  defp attentive_delay do
    base = div(Engine.config(:director_interval_ms), 3)
    base + :rand.uniform(max(div(base, 2), 1))
  end

  defp remaining(timer) do
    case Process.read_timer(timer) do
      false -> 0
      milliseconds -> milliseconds
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
