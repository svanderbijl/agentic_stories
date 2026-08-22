defmodule AgenticStories.Engine.Supervisor do
  @moduledoc """
  Supervises the engine runtime: the registry of character agents, the
  dynamic supervisor they run under, the task supervisor for weaving, and
  the player-presence table the agents read before they take a turn.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: AgenticStories.Engine.Registry},
      AgenticStories.Engine.Presence,
      {DynamicSupervisor,
       name: AgenticStories.Engine.CharacterSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: AgenticStories.Engine.TaskSupervisor},
      # a restart mid-weave orphans the story; fray it at boot
      {Task, &AgenticStories.Stories.fray_orphaned_weaves/0}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
