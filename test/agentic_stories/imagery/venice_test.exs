defmodule AgenticStories.Imagery.VeniceTest do
  use ExUnit.Case, async: true

  alias AgenticStories.Imagery.Venice

  test "posts the prompt to /v1/image/generate with safe mode off and decodes the image" do
    Req.Test.stub(Venice, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/image/generate"
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert body["prompt"] =~ "portrait"
      assert is_binary(body["model"])
      assert body["safe_mode"] == false
      assert body["hide_watermark"] == true
      assert body["format"] == "jpeg"

      # sizing is model-specific — a pixel model's width/height sent to an
      # aspect-ratio model rejects the whole request, so we send neither
      # unless :params says to
      refute Map.has_key?(body, "width")
      refute Map.has_key?(body, "height")
      refute Map.has_key?(body, "aspect_ratio")

      Req.Test.json(conn, %{"images" => [Base.encode64(<<255, 216, 255>>)]})
    end)

    assert {:ok, %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}} =
             Venice.generate("A photorealistic portrait of Maren.")
  end

  test "configured params ride along, without overriding what the driver sets" do
    config = Application.fetch_env!(:agentic_stories, Venice)
    on_exit(fn -> Application.put_env(:agentic_stories, Venice, config) end)

    Application.put_env(
      :agentic_stories,
      Venice,
      Keyword.put(config, :params, %{aspect_ratio: "16:9", safe_mode: true})
    )

    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert body["aspect_ratio"] == "16:9"
      # safe mode is the driver's call, not config's
      assert body["safe_mode"] == false

      Req.Test.json(conn, %{"images" => [Base.encode64(<<1>>)]})
    end)

    assert {:ok, %{binary: <<1>>}} = Venice.generate("a wide shot")
  end

  test "compose posts data URIs to /v1/image/multi-edit and returns the raw image" do
    reference = %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}

    Req.Test.stub(Venice, fn conn ->
      assert conn.request_path == "/api/v1/image/multi-edit"

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert is_binary(body["modelId"])
      assert body["prompt"] == "the crew at the rail"

      assert ["data:image/jpeg;base64," <> _, "data:image/jpeg;base64," <> _] =
               body["images"]

      # this endpoint defaults safe_mode to TRUE — leaving it out blurs the
      # very output this project is on Venice for
      assert body["safe_mode"] == false

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
    end)

    assert {:ok, %{binary: <<1, 2, 3>>, content_type: "image/jpeg"}} =
             Venice.compose("the crew at the rail", [reference, reference])
  end

  test "compose without references falls back to plain generation" do
    Req.Test.stub(Venice, fn conn ->
      assert conn.request_path == "/api/v1/image/generate"
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, %{"images" => [Base.encode64(<<1>>)]})
    end)

    assert {:ok, %{binary: <<1>>}} = Venice.compose("empty deck", [])
  end

  test "returns an error tuple for non-200 responses" do
    Req.Test.stub(Venice, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(422, ~s({"error": "prompt rejected"}))
    end)

    assert {:error, {:http_error, 422, _body}} = Venice.generate("portrait")

    assert {:error, {:http_error, 422, _body}} =
             Venice.compose("scene", [%{binary: <<1>>, content_type: "image/png"}])
  end

  test "returns an error tuple for unexpected payloads" do
    Req.Test.stub(Venice, fn conn ->
      Req.Test.json(conn, %{"images" => []})
    end)

    assert {:error, {:unexpected_response, _body}} = Venice.generate("portrait")
  end
end
