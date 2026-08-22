defmodule AgenticStoriesWeb.StoryLiveTest do
  # async: false — the LiveView process shares the sandbox in shared mode
  use AgenticStoriesWeb.ConnCase, async: false

  import AgenticStories.StoriesFixtures
  import Phoenix.LiveViewTest

  alias AgenticStories.Stories

  describe "a weaving story" do
    test "shows the loom with the seed", %{conn: conn} do
      story = weaving_story_fixture(%{seed: "A door under the sea."})

      {:ok, _view, html} = live(conn, ~p"/stories/#{story}")

      assert html =~ "The Weaver is at work"
      assert html =~ "A door under the sea."
      refute html =~ "composer-form"
    end

    test "turns into the scene when the weave completes", %{conn: conn} do
      story = weaving_story_fixture()
      {:ok, view, _html} = live(conn, ~p"/stories/#{story}")

      {:ok, _story} =
        Stories.complete_weaving(story, %{
          title: "The Door Below",
          premise: "p",
          arc: "a",
          tone: "quietly ominous",
          style: "s",
          opening: "The tide pulls back further than it should.",
          characters: [%{name: "Maren", persona: "The keeper's sister.", energy: 2}]
        })

      # the broadcast is already in the view's mailbox; get_state syncs on it
      :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "The Door Below"
      assert html =~ "The tide pulls back further than it should."
      assert html =~ "Maren"
      assert html =~ "composer-form"
    end
  end

  describe "a live story" do
    setup %{conn: conn} do
      story = story_fixture()
      character = character_fixture(story)
      message_fixture(story, %{kind: :narration, content: "The tide pulls back."})

      message_fixture(story, %{
        kind: :say,
        content: "You should not be out here.",
        character_id: character.id
      })

      {:ok, view, html} = live(conn, ~p"/stories/#{story}")
      %{story: story, character: character, view: view, html: html}
    end

    test "renders title, cast, and the beats so far", ctx do
      assert ctx.html =~ "The Door Below"
      assert ctx.html =~ "Maren"
      assert ctx.html =~ "The tide pulls back."
      assert ctx.html =~ "You should not be out here."
    end

    test "a character's agenda and arc are never rendered", ctx do
      refute ctx.html =~ "lied about it"
      refute ctx.html =~ "finally tells it"
    end

    test "a thinking signal shows the quill on the cast", ctx do
      character = ctx.character

      Stories.signal_thinking(ctx.story.id, character.id, true)
      :sys.get_state(ctx.view.pid)
      assert render(ctx.view) =~ "✎"

      Stories.signal_thinking(ctx.story.id, character.id, false)
      :sys.get_state(ctx.view.pid)
      refute render(ctx.view) =~ "✎"
    end

    test "sending a message records and renders the player's beat", ctx do
      ctx.view
      |> form("#composer-form", %{"content" => "Hello? Anyone there?"})
      |> render_submit()

      # the beat arrives via the story's own message_created broadcast
      :sys.get_state(ctx.view.pid)
      assert render(ctx.view) =~ "Hello? Anyone there?"
      assert_push_event(ctx.view, "composer:clear", %{})

      assert [%{kind: :player, content: "Hello? Anyone there?"}] =
               Stories.list_messages(ctx.story.id) |> Enum.filter(&(&1.kind == :player))
    end

    test "a blank message records nothing", ctx do
      ctx.view
      |> form("#composer-form", %{"content" => "   "})
      |> render_submit()

      assert Stories.list_messages(ctx.story.id) |> Enum.filter(&(&1.kind == :player)) == []
    end

    test "a character's beat appears without refresh", ctx do
      {:ok, _message} =
        Stories.create_message(ctx.story, %{
          kind: :act,
          content: "lights the lamp",
          character_id: ctx.character.id
        })

      :sys.get_state(ctx.view.pid)
      assert render(ctx.view) =~ "lights the lamp"
    end
  end

  describe "witnessing and the world" do
    setup %{conn: conn} do
      story = story_fixture()
      lamp_room = location_fixture(story, %{name: "The Lamp Room"})
      shore = location_fixture(story, %{name: "The Shore"})
      {:ok, story} = AgenticStories.Stories.move_player(story, lamp_room.id)

      near = character_fixture(story, %{name: "Maren", location_id: lamp_room.id})
      far = character_fixture(story, %{name: "Old Tosk", location_id: shore.id})

      message_fixture(story, %{
        kind: :say,
        content: "The light is wrong tonight.",
        character_id: near.id,
        location_id: lamp_room.id
      })

      message_fixture(story, %{
        kind: :act,
        content: "drags something up the shingle",
        character_id: far.id,
        location_id: shore.id,
        witnessed_by_player: false
      })

      {:ok, view, html} = live(conn, ~p"/stories/#{story}")
      %{story: story, lamp_room: lamp_room, shore: shore, view: view, html: html}
    end

    test "the reading pane holds only what the player witnessed", ctx do
      assert ctx.html =~ "The light is wrong tonight."
      refute ctx.html =~ "drags something up the shingle"
    end

    test "unwitnessed broadcasts stay out of the pane", ctx do
      {:ok, _message} =
        Stories.create_message(ctx.story, %{
          kind: :say,
          content: "Nobody up there hears me.",
          location_id: ctx.shore.id
        })

      :sys.get_state(ctx.view.pid)
      refute render(ctx.view) =~ "Nobody up there hears me."
    end

    test "the world panel shows places and where you are", ctx do
      assert ctx.html =~ "The world"
      assert ctx.html =~ "The Lamp Room"
      assert ctx.html =~ "you are here"
      assert ctx.html =~ "elsewhere"
    end

    test "going somewhere relocates the player, narrates the move, and surfaces residue", ctx do
      # the unwitnessed shore beat becomes residue on arrival
      Mox.stub(AgenticStories.LLM.Mock, :chat, fn _request ->
        {:ok, %AgenticStories.LLM.Response{text: "The shingle is churned in a long furrow."}}
      end)

      Stories.subscribe(ctx.story.id)

      ctx.view
      |> element("aside button[phx-value-id='#{ctx.shore.id}']")
      |> render_click()

      :sys.get_state(ctx.view.pid)
      html = render(ctx.view)

      assert html =~ "You make your way to The Shore."
      assert Stories.get_story!(ctx.story.id).player_location_id == ctx.shore.id

      assert_receive {:message_created,
                      %{kind: :narration, content: "The shingle is churned" <> _}},
                     1_000
    end
  end

  describe "ending and deleting" do
    test "the end button closes the book in place", %{conn: conn} do
      story = story_fixture()
      {:ok, view, _html} = live(conn, ~p"/stories/#{story}")

      view
      |> element("aside button[phx-click='end_story']")
      |> render_click()

      :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "The end"
      assert html =~ "Here you close the book"
      refute html =~ "composer-form"
      assert AgenticStories.Stories.get_story!(story.id).status == :finished
    end

    test "the delete button removes the story and returns home", %{conn: conn} do
      story = story_fixture()
      {:ok, view, _html} = live(conn, ~p"/stories/#{story}")

      view
      |> element("aside button[phx-click='delete_story']")
      |> render_click()

      flash = assert_redirect(view, "/")
      assert flash["info"] == "The story is gone."
      assert AgenticStories.Stories.list_stories() == []
    end

    test "a frayed story can be deleted from its own page", %{conn: conn} do
      story = weaving_story_fixture()
      {:ok, story} = Stories.fail_weaving(story, "the weave came apart")

      {:ok, view, html} = live(conn, ~p"/stories/#{story}")
      assert html =~ "delete story"

      view
      |> element("button[phx-click='delete_story']")
      |> render_click()

      assert_redirect(view, "/")
      assert AgenticStories.Stories.list_stories() == []
    end
  end

  describe "a finished story" do
    test "shows the colophon and retires the composer", %{conn: conn} do
      story = story_fixture(%{status: :finished})
      message_fixture(story, %{kind: :narration, content: "And the tide came back."})

      {:ok, _view, html} = live(conn, ~p"/stories/#{story}")

      assert html =~ "And the tide came back."
      assert html =~ "The end"
      refute html =~ "composer-form"
      refute html =~ ">go <"
    end
  end

  describe "a frayed story" do
    test "shows the failure and the way home", %{conn: conn} do
      story = weaving_story_fixture()
      {:ok, story} = Stories.fail_weaving(story, "the weave came apart mid-thread")

      {:ok, _view, html} = live(conn, ~p"/stories/#{story}")

      assert html =~ "The weave came apart"
      assert html =~ "mid-thread"
      assert html =~ "Bring a new seed"
    end
  end
end
