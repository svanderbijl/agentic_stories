defmodule AgenticStoriesWeb.PlateController do
  @moduledoc "Serves chapter-illustration plates straight from the database."

  use AgenticStoriesWeb, :controller

  import AgenticStoriesWeb.ImageServing

  alias AgenticStories.Stories

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {binary, content_type} <- Stories.get_illustration(id) do
      serve_image(conn, binary, content_type)
    else
      _ -> send_resp(conn, 404, "no plate")
    end
  end
end
