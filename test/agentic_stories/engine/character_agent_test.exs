defmodule AgenticStories.Engine.CharacterAgentTest do
  # async: false — agents are separate processes; the shared sandbox mode
  # gives them database access without per-pid allowances.
  use AgenticStories.DataCase, async: false

  import AgenticStories.StoriesFixtures
  import Mox

  alias AgenticStories.Engine.CharacterAgent
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Response
  alias AgenticStories.Stories
  alias AgenticStories.Stories.Message

  setup :set_mox_global
  setup :verify_on_exit!

  # The test tick interval is 60s, so scheduled ticks never fire on their own;
  # every tick in here is driven explicitly with `send(pid, :tick)`. The
  # fixture's energy of 2 funds exactly one tick (tick_cost is 2).
  defp start_agent(story, character) do
    start_supervised!({CharacterAgent, character: character, story: story})
  end

  setup do
    story = story_fixture()
    character = character_fixture(story, %{energy: 2})
    Stories.subscribe(story.id)
    %{story: story, character: character}
  end

  test "a tick spends energy and records the character's line", ctx do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok, %Response{text: ~s({"do": "say", "text": "Only me."})}}
    end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    assert_receive {:message_created, %Message{kind: :say, content: "Only me."}}, 1_000
    assert %{energy: 0, dormant?: false} = :sys.get_state(pid)
    assert Stories.get_character!(ctx.character.id).energy == 0
  end

  test "a wait decision spends energy but records nothing", ctx do
    expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: ~s({"do": "wait"})}} end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    assert %{energy: 0} = :sys.get_state(pid)
    refute_receive {:message_created, _message}, 50
  end

  test "an agent without a full tick's energy goes dormant without thinking", ctx do
    character = struct!(ctx.character, energy: 1)
    pid = start_agent(ctx.story, character)

    send(pid, :tick)

    # No LLM.Mock expectation is set: a call would raise and crash the agent.
    assert %{energy: 1, dormant?: true} = :sys.get_state(pid)
  end

  test "energize wakes a dormant agent and caps energy", ctx do
    character = struct!(ctx.character, energy: 0)
    pid = start_agent(ctx.story, character)
    send(pid, :tick)
    assert %{dormant?: true} = :sys.get_state(pid)

    CharacterAgent.energize(ctx.character.id, 100, :player)

    assert %{energy: 12, dormant?: false} = :sys.get_state(pid)
    assert Stories.get_character!(ctx.character.id).energy == 12
  end

  test "retires once the idle deadline has passed, energy or not", ctx do
    pid = start_agent(ctx.story, ctx.character)
    ref = Process.monitor(pid)

    :sys.replace_state(pid, fn state ->
      %{state | idle_deadline: System.monotonic_time(:millisecond) - 1}
    end)

    send(pid, :retire)
    # Registry cleanup after the exit is async, so the DOWN is the proof here
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "player energy extends the idle deadline; chatter does not", ctx do
    pid = start_agent(ctx.story, ctx.character)
    ref = Process.monitor(pid)

    past = System.monotonic_time(:millisecond) - 1
    :sys.replace_state(pid, fn state -> %{state | idle_deadline: past} end)
    CharacterAgent.energize(ctx.character.id, 1, :player)
    send(pid, :retire)

    # the deadline was refreshed, so the agent lives on
    assert %{dormant?: false} = :sys.get_state(pid)

    :sys.replace_state(pid, fn state -> %{state | idle_deadline: past} end)
    CharacterAgent.energize(ctx.character.id, 1, :chatter)
    send(pid, :retire)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "a player message pulls the pending tick forward", ctx do
    pid = start_agent(ctx.story, ctx.character)

    %{tick_timer: timer} = :sys.get_state(pid)
    assert Process.read_timer(timer) > 30_000

    CharacterAgent.energize(ctx.character.id, 1, :player)

    %{tick_timer: hastened} = :sys.get_state(pid)
    assert Process.read_timer(hastened) < 15_000
  end

  test "ambient energy wakes a dormant agent only lazily", ctx do
    character = struct!(ctx.character, energy: 0)
    pid = start_agent(ctx.story, character)
    send(pid, :tick)
    assert %{dormant?: true} = :sys.get_state(pid)

    CharacterAgent.energize(ctx.character.id, 2, :ambient)

    %{dormant?: false, tick_timer: timer} = :sys.get_state(pid)
    assert Process.read_timer(timer) > 30_000
  end

  test "consolidates fading beats into memory before thinking", ctx do
    config = Application.fetch_env!(:agentic_stories, AgenticStories.Engine)
    on_exit(fn -> Application.put_env(:agentic_stories, AgenticStories.Engine, config) end)

    Application.put_env(
      :agentic_stories,
      AgenticStories.Engine,
      Keyword.put(config, :memory_window, 2)
    )

    for n <- 1..5 do
      message_fixture(ctx.story, %{kind: :player, content: "beat #{n}"})
    end

    expect(LLM.Mock, :chat, 2, fn request ->
      if request.system =~ "journal" do
        {:ok, %Response{text: "I remember the first two beats."}}
      else
        {:ok, %Response{text: ~s({"do": "wait"})}}
      end
    end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    assert %{character: %{memory_beats: 2}} = :sys.get_state(pid)

    assert [%{content: "I remember the first two beats."}] =
             Stories.list_memories(ctx.character)
  end

  test "a line that collides with new DIALOGUE is held back and retried soon", ctx do
    story = ctx.story

    expect(LLM.Mock, :chat, fn _request ->
      # the player speaks while this character is thinking
      {:ok, _} =
        Stories.create_message(story, %{kind: :player, content: "Wait — one more thing."})

      {:ok, %Response{text: ~s({"do": "say", "text": "How quiet it is."})}}
    end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    %{tick_timer: timer} = :sys.get_state(pid)
    contents = story.id |> Stories.list_messages() |> Enum.map(& &1.content)
    refute "How quiet it is." in contents
    # held lines retry at the wake delay, not the full cadence
    assert Process.read_timer(timer) < 15_000
  end

  test "background acts and narration never cancel a drafted line", ctx do
    story = ctx.story
    barkeep = character_fixture(story, %{name: "Dez", energy: 0})

    expect(LLM.Mock, :chat, fn _request ->
      # scenery shifts mid-think: an act by someone else and a narration
      {:ok, _} =
        Stories.create_message(story, %{
          kind: :act,
          content: "wipes down the bar",
          character_id: barkeep.id
        })

      {:ok, _} = Stories.create_message(story, %{kind: :narration, content: "The music dips."})
      {:ok, %Response{text: ~s({"do": "say", "text": "Only me."})}}
    end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)
    :sys.get_state(pid)

    contents = story.id |> Stories.list_messages() |> Enum.map(& &1.content)
    assert "Only me." in contents
  end

  test "an addressed character who tries to wait is made to try again soon", ctx do
    # alone with the player, and the player's beat is the newest thing seen
    message_fixture(ctx.story, %{kind: :player, content: "Well? Say something."})

    expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: ~s({"do": "wait"})}} end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    %{tick_timer: timer} = :sys.get_state(pid)
    # the answer is owed: retry at the wake delay, not the full cadence
    assert Process.read_timer(timer) < 15_000
  end

  test "an unaddressed wait keeps the normal cadence", ctx do
    message_fixture(ctx.story, %{kind: :narration, content: "The tide pulls back."})

    expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: ~s({"do": "wait"})}} end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)

    %{tick_timer: timer} = :sys.get_state(pid)
    assert Process.read_timer(timer) > 30_000
  end

  test "a dying agent clears its thinking quill", ctx do
    pid = start_agent(ctx.story, ctx.character)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000

    character_id = ctx.character.id
    assert_receive {:character_thinking, ^character_id, false}
  end

  test "a repeated line is held back", ctx do
    message_fixture(ctx.story, %{
      kind: :say,
      content: "Only me.",
      character_id: ctx.character.id
    })

    expect(LLM.Mock, :chat, fn _request ->
      {:ok, %Response{text: ~s({"do": "say", "text": "Only me."})}}
    end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)
    :sys.get_state(pid)

    says = ctx.story.id |> Stories.list_messages() |> Enum.filter(&(&1.kind == :say))
    assert length(says) == 1
  end

  test "thinking is signalled around the decision", ctx do
    expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: ~s({"do": "wait"})}} end)

    pid = start_agent(ctx.story, ctx.character)
    send(pid, :tick)
    :sys.get_state(pid)

    character_id = ctx.character.id
    assert_receive {:character_thinking, ^character_id, true}
    assert_receive {:character_thinking, ^character_id, false}
  end

  test "agents register by character id", ctx do
    pid = start_agent(ctx.story, ctx.character)
    assert CharacterAgent.whereis(ctx.character.id) == pid
    assert CharacterAgent.whereis(ctx.character.id + 1) == nil
  end
end
