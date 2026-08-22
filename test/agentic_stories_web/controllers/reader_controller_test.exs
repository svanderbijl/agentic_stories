defmodule AgenticStoriesWeb.ReaderControllerTest do
  use AgenticStoriesWeb.ConnCase, async: true

  import AgenticStories.StoriesFixtures

  test "typesets the witnessed story as one page", %{conn: conn} do
    story = story_fixture(%{status: :finished})
    character = character_fixture(story)
    message_fixture(story, %{kind: :narration, content: "The tide pulls back."})

    message_fixture(story, %{
      kind: :say,
      content: "You should not be out here.",
      character_id: character.id
    })

    message_fixture(story, %{kind: :player, content: "Maren, look."})

    html = conn |> get(~p"/stories/#{story}/read") |> html_response(200)

    assert html =~ story.title
    assert html =~ story.premise
    assert html =~ "The tide pulls back."
    assert html =~ "You should not be out here."
    assert html =~ "Maren, look."
    assert html =~ "The end"
    # the reader page never leaks unwitnessed material or agendas
    refute html =~ "lied about it"
  end

  test "redirects to the story page while the weave is still on the loom", %{conn: conn} do
    story = weaving_story_fixture()

    conn = get(conn, ~p"/stories/#{story}/read")
    assert redirected_to(conn) == ~p"/stories/#{story}"
  end

  test "leaves unwitnessed beats out", %{conn: conn} do
    story = story_fixture()
    message_fixture(story, %{kind: :act, content: "digs in secret", witnessed_by_player: false})

    html = conn |> get(~p"/stories/#{story}/read") |> html_response(200)
    refute html =~ "digs in secret"
  end
end
