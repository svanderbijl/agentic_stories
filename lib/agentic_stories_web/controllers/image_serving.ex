defmodule AgenticStoriesWeb.ImageServing do
  @moduledoc """
  Serves database-stored images with ETag revalidation instead of time-based
  caching. Ids restart from 1 after a dev database reset, so a plain
  `max-age` would dress new characters in old portraits; `no-cache` plus a
  strong ETag means the browser always revalidates and almost always gets a
  cheap 304.
  """

  import Plug.Conn

  def serve_image(conn, binary, content_type) do
    etag = ~s(") <> Base.encode16(:erlang.md5(binary), case: :lower) <> ~s(")

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "public, no-cache")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type(content_type)
      |> send_resp(200, binary)
    end
  end
end
