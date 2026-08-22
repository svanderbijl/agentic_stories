defmodule AgenticStoriesWeb.AvatarController do
  @moduledoc """
  Serves character portraits straight from the database. The UI only links
  here for characters whose avatar exists (`avatar_type` is set).
  """

  use AgenticStoriesWeb, :controller

  import AgenticStoriesWeb.ImageServing

  alias AgenticStories.Stories

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {binary, content_type} <- Stories.get_avatar(id) do
      serve_image(conn, binary, content_type)
    else
      _ -> send_resp(conn, 404, "no portrait")
    end
  end
end
