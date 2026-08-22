defmodule AgenticStories.Imagery.GrokImagineTest do
  use ExUnit.Case, async: true

  alias AgenticStories.Imagery.GrokImagine

  test "posts the prompt to /v1/images/generations and decodes the image" do
    Req.Test.stub(GrokImagine, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/images/generations"
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["prompt"] =~ "portrait"
      assert body["response_format"] == "b64_json"
      assert is_binary(body["model"])

      Req.Test.json(conn, %{"data" => [%{"b64_json" => Base.encode64(<<255, 216, 255>>)}]})
    end)

    assert {:ok, %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}} =
             GrokImagine.generate("A painterly portrait of Maren.")
  end

  test "compose sends one reference as an object and several as a list" do
    reference = %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}

    Req.Test.stub(GrokImagine, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      case body["prompt"] do
        "single" ->
          assert %{"type" => "image_url", "url" => "data:image/jpeg;base64," <> _} =
                   body["image"]

        "several" ->
          assert [%{"type" => "image_url"}, %{"type" => "image_url"}] = body["image"]

        "none" ->
          refute Map.has_key?(body, "image")
      end

      Req.Test.json(conn, %{"data" => [%{"b64_json" => Base.encode64(<<1>>)}]})
    end)

    assert {:ok, _image} = GrokImagine.compose("single", [reference])
    assert {:ok, _image} = GrokImagine.compose("several", [reference, reference])
    assert {:ok, _image} = GrokImagine.compose("none", [])
  end

  test "returns an error tuple for non-200 responses" do
    Req.Test.stub(GrokImagine, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(422, ~s({"error": "prompt rejected"}))
    end)

    assert {:error, {:http_error, 422, _body}} = GrokImagine.generate("portrait")
  end

  test "returns an error tuple for unexpected payloads" do
    Req.Test.stub(GrokImagine, fn conn ->
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:error, {:unexpected_response, _body}} = GrokImagine.generate("portrait")
  end
end
