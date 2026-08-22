defmodule AgenticStoriesWeb.HomeLiveTest do
  # async: false — seeding weaves in a background task under the shared sandbox
  use AgenticStoriesWeb.ConnCase, async: false

  import AgenticStories.StoriesFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias AgenticStories.LLM
  alias AgenticStories.LLM.Response
  alias AgenticStories.Stories
  alias AgenticStories.Stories.Story

  setup :set_mox_global
  setup :verify_on_exit!

  test "renders the invitation and the shelf", %{conn: conn} do
    story_fixture(%{title: "The Door Below"})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Stories that"
    assert html =~ "The Door Below"
  end

  test "hides the shelf when there are no stories yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ "The shelf"
  end

  test "seeding a story navigates to it and weaves in the background", %{conn: conn} do
    stub(LLM.Mock, :chat, fn _request ->
      {:ok,
       %Response{
         text:
           Jason.encode!(%{
             "title" => "The Door Below",
             "premise" => "p",
             "arc" => "a",
             "tone" => "t",
             "style" => "s",
             "opening" => "The tide pulls back.",
             "opening_location" => "The Shore",
             "locations" => [%{"name" => "The Shore", "description" => "Wet shingle."}],
             "characters" => [%{"name" => "Maren", "persona" => "The keeper's sister."}]
           })
       }}
    end)

    Stories.subscribe()
    {:ok, view, _html} = live(conn, ~p"/")

    result =
      view
      |> form("#seed-form", %{"seed" => "A door under the sea."})
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/stories/" <> id}}} = result

    # wait for the background weave so the test exits with a quiet sandbox
    assert_receive {:story_updated, %Story{status: :live}}, 2_000
    assert Stories.get_story!(id).seed == "A door under the sea."
  end

  test "an empty seed shows an error and stays put", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#seed-form", %{"seed" => "  "})
      |> render_submit()

    assert html =~ "at least a few words"
    assert Stories.list_stories() == []
  end

  test "an example seed fills the textarea", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("button[phx-click=use_example]", "lighthouse keeper")
      |> render_click()

    assert html =~ "A lighthouse keeper finds a door at the bottom of the sea."
  end
end
