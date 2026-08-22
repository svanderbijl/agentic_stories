defmodule AgenticStoriesWeb.AvatarControllerTest do
  use AgenticStoriesWeb.ConnCase, async: true

  import AgenticStories.StoriesFixtures

  alias AgenticStories.Stories

  test "serves a stored portrait with its content type", %{conn: conn} do
    story = story_fixture()
    character = character_fixture(story)
    {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")

    conn = get(conn, ~p"/avatars/#{character.id}")

    assert response(conn, 200) == <<255, 216, 255>>
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
  end

  test "404s for characters without a portrait", %{conn: conn} do
    story = story_fixture()
    character = character_fixture(story)

    assert conn |> get(~p"/avatars/#{character.id}") |> response(404)
  end

  test "404s for nonsense ids", %{conn: conn} do
    assert conn |> get(~p"/avatars/not-a-character") |> response(404)
  end
end
