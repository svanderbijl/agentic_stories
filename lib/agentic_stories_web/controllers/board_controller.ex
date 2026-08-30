defmodule AgenticStoriesWeb.BoardController do
  @moduledoc """
  Serves character-design sheets straight from the database. The UI only
  links here when a sheet exists (`board_type` / `player_board_type`).
  """

  use AgenticStoriesWeb, :controller

  import AgenticStoriesWeb.ImageServing

  alias AgenticStories.Stories

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {binary, content_type} <- Stories.get_board(id) do
      serve_image(conn, binary, content_type)
    else
      _ -> send_resp(conn, 404, "no sheet")
    end
  end

  def player(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {binary, content_type} <- Stories.get_player_board(id) do
      serve_image(conn, binary, content_type)
    else
      _ -> send_resp(conn, 404, "no sheet")
    end
  end
end
