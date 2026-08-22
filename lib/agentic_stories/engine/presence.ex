defmodule AgenticStories.Engine.Presence do
  @moduledoc """
  Whether the player currently has their hands on the keyboard, per story.

  A scene should yield to a person who is mid-sentence: the composer stamps
  this table on every keystroke, and both the cast and the Director check it
  before they spend a tick. The hold expires by itself `typing_grace_ms`
  after the last keystroke, so an abandoned draft can never freeze a story.

  Deliberately process-free: a tick asks "is the player writing?" with one
  ETS read, never a call into another process that might itself be blocked
  on an LLM.
  """

  use GenServer

  alias AgenticStories.Engine

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The player is composing in this story; refreshes the hold."
  @spec typing(integer()) :: :ok
  def typing(story_id) do
    :ets.insert(@table, {story_id, now_ms()})
    :ok
  end

  @doc "The draft was sent or abandoned; drops the hold immediately."
  @spec stopped_typing(integer()) :: :ok
  def stopped_typing(story_id) do
    :ets.delete(@table, story_id)
    :ok
  end

  @doc "Is the player mid-sentence right now?"
  @spec typing?(integer()) :: boolean()
  def typing?(story_id) do
    case :ets.lookup(@table, story_id) do
      [{_story_id, at}] -> now_ms() - at < Engine.config(:typing_grace_ms)
      [] -> false
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
