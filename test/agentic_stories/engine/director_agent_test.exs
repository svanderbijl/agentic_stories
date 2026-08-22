defmodule AgenticStories.Engine.DirectorAgentTest do
  # async: false — the shared sandbox gives the agent database access.
  use AgenticStories.DataCase, async: false

  import AgenticStories.StoriesFixtures
  import Mox

  alias AgenticStories.Engine
  alias AgenticStories.Engine.{CharacterAgent, DirectorAgent}
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Response
  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Message, Story}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    story = story_fixture()
    location = location_fixture(story, %{name: "The Lamp Room"})
    {:ok, story} = Stories.move_player(story, location.id)
    character = character_fixture(story, %{energy: 0, location_id: location.id})
    Stories.subscribe(story.id)
    %{story: story, location: location, character: character}
  end

  test "the Director does not narrate over a player who is mid-sentence", ctx do
    Engine.player_typing(ctx.story)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    send(pid, :tick)

    # no LLM call, no energy spent — the look simply comes back around
    assert %{energy: energy} = :sys.get_state(pid)
    assert energy == AgenticStories.Engine.config(:director_energy)
    refute_receive {:message_created, _message}, 50
  end

  test "a narrate direction lands as narration and stirs the room", ctx do
    expect(LLM.Mock, :chat, fn request ->
      assert request.system =~ "Director"

      {:ok,
       %Response{
         text: ~s({"do": "narrate", "text": "The lamp gutters.", "location": "The Lamp Room"})
       }}
    end)

    character_pid =
      start_supervised!({CharacterAgent, character: ctx.character, story: ctx.story}, id: :char)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    send(pid, :tick)

    assert_receive {:message_created, %Message{kind: :narration, content: "The lamp gutters."}},
                   1_000

    # the stir is a cast racing our assertion; sync through the director
    :sys.get_state(pid)

    # chatter-level stimulus reached the character in that room
    assert %{energy: 1} = :sys.get_state(character_pid)
  end

  test "a nudge direction whispers to the character and hastens them", ctx do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok, %Response{text: ~s({"do": "nudge", "character": "Maren", "note": "Say it now."})}}
    end)

    character_pid =
      start_supervised!({CharacterAgent, character: ctx.character, story: ctx.story}, id: :char)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    send(pid, :tick)

    # the nudge is a cast racing our assertion; sync through the agent
    :sys.get_state(pid)
    assert %{character: %{nudge: "Say it now."}, energy: 6} = :sys.get_state(character_pid)
  end

  test "a reveal direction opens a new place", ctx do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok,
       %Response{
         text: ~s({"do": "reveal", "name": "Beyond the Door", "description": "Dark water."})
       }}
    end)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    send(pid, :tick)

    assert_receive {:location_created, %{name: "Beyond the Door"}}, 1_000
    assert Enum.any?(Stories.list_locations(ctx.story.id), &(&1.name == "Beyond the Door"))
  end

  test "a conclude direction finishes the story and retires everyone", ctx do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok, %Response{text: ~s({"do": "conclude", "text": "And the tide came back."})}}
    end)

    character_pid =
      start_supervised!({CharacterAgent, character: ctx.character, story: ctx.story}, id: :char)

    Process.unlink(character_pid)
    character_ref = Process.monitor(character_pid)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, :tick)

    assert_receive {:message_created,
                    %Message{kind: :narration, content: "And the tide came back."}},
                   1_000

    assert_receive {:story_updated, %Story{status: :finished}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_receive {:DOWN, ^character_ref, :process, ^character_pid, _reason}, 1_000
  end

  test "player activity pulls the Director's next look forward", ctx do
    pid = start_supervised!({DirectorAgent, story: ctx.story})

    # the idle schedule waits at least the full interval; an energize pulls
    # the look to a third of it (both plus jitter, so compare at the midpoint)
    interval = AgenticStories.Engine.config(:director_interval_ms)

    %{tick_timer: timer} = :sys.get_state(pid)
    assert Process.read_timer(timer) > div(interval, 2)

    DirectorAgent.energize(ctx.story.id, 6)

    %{tick_timer: hastened} = :sys.get_state(pid)
    assert Process.read_timer(hastened) <= div(interval, 2)
  end

  test "a director of a story that is no longer live stops quietly", ctx do
    {:ok, _story} = Stories.finish_story(ctx.story)

    pid = start_supervised!({DirectorAgent, story: ctx.story})
    Process.unlink(pid)
    ref = Process.monitor(pid)

    send(pid, :tick)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
