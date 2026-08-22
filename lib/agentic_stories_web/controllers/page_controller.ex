defmodule AgenticStoriesWeb.PageController do
  use AgenticStoriesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
