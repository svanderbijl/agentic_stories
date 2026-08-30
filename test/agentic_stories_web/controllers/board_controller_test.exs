defmodule AgenticStoriesWeb.BoardControllerTest do
  use AgenticStoriesWeb.ConnCase, async: true

  import AgenticStories.StoriesFixtures

  alias AgenticStories.Stories

  test "serves a stored character sheet with its content type", %{conn: conn} do
    story = story_fixture()
    character = character_fixture(story)
    {:ok, _} = Stories.put_character_board(character, <<1, 2, 3>>, "image/jpeg")

    conn = get(conn, ~p"/boards/#{character.id}")

    assert response(conn, 200) == <<1, 2, 3>>
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
  end

  test "404s for characters without a sheet", %{conn: conn} do
    story = story_fixture()
    character = character_fixture(story)

    assert conn |> get(~p"/boards/#{character.id}") |> response(404)
  end

  test "serves the player's stored sheet", %{conn: conn} do
    story = story_fixture()
    {:ok, _} = Stories.put_player_board(story, <<1, 2, 3>>, "image/jpeg")

    conn = get(conn, ~p"/player-boards/#{story.id}")

    assert response(conn, 200) == <<1, 2, 3>>
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
  end

  test "404s when the player has no sheet", %{conn: conn} do
    story = story_fixture()
    assert conn |> get(~p"/player-boards/#{story.id}") |> response(404)
  end

  test "404s for nonsense ids", %{conn: conn} do
    assert conn |> get(~p"/boards/not-a-character") |> response(404)
    assert conn |> get(~p"/player-boards/nope") |> response(404)
  end
end
