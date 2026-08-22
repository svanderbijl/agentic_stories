defmodule AgenticStoriesWeb.PlateControllerTest do
  use AgenticStoriesWeb.ConnCase, async: true

  import AgenticStories.StoriesFixtures

  alias AgenticStories.Stories

  test "serves an illustration plate with its content type", %{conn: conn} do
    story = story_fixture()

    {:ok, message} =
      Stories.create_message(story, %{
        kind: :illustration,
        content: "The door, ajar.",
        image: <<255, 216, 255>>,
        image_type: "image/jpeg"
      })

    conn = get(conn, ~p"/plates/#{message.id}")
    assert response(conn, 200) == <<255, 216, 255>>
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
  end

  test "404s for beats that are not plates", %{conn: conn} do
    story = story_fixture()
    message = message_fixture(story)

    assert conn |> get(~p"/plates/#{message.id}") |> response(404)
    assert conn |> get(~p"/plates/not-a-plate") |> response(404)
  end
end
