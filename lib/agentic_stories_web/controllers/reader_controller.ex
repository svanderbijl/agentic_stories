defmodule AgenticStoriesWeb.ReaderController do
  @moduledoc """
  Reader mode: the story the player witnessed, typeset as one continuous
  book page — printable, shareable, and the natural resting place of a
  finished story.
  """

  use AgenticStoriesWeb, :controller

  alias AgenticStories.Stories

  def show(conn, %{"id" => id}) do
    story = Stories.get_story!(id)

    if story.status in [:live, :finished] do
      render(conn, :show,
        story: story,
        beats: Stories.player_messages(story.id),
        page_title: story.title
      )
    else
      # nothing to read yet — back to the loom (or the fray)
      redirect(conn, to: ~p"/stories/#{story}")
    end
  end
end
