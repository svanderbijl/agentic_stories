defmodule AgenticStories.LLM.ClaudeTest do
  use ExUnit.Case, async: true

  alias AgenticStories.LLM.{Claude, Request, Response}

  defp request(attrs \\ []) do
    struct!(
      %Request{
        model: "claude-haiku-4-5",
        system: "You are Maren.",
        messages: [%{role: :user, content: "Your move."}],
        max_tokens: 1024
      },
      attrs
    )
  end

  test "posts the request to /v1/messages with Anthropic headers" do
    Req.Test.stub(Claude, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages"
      assert ["test-key"] = Plug.Conn.get_req_header(conn, "x-api-key")
      assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert body["model"] == "claude-haiku-4-5"
      assert body["max_tokens"] == 1024
      assert [%{"role" => "user", "content" => "Your move."}] = body["messages"]

      assert [%{"type" => "text", "text" => "You are Maren.", "cache_control" => _}] =
               body["system"]

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => ~s({"do": "wait"})}],
        "model" => "claude-haiku-4-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 42, "output_tokens" => 7}
      })
    end)

    assert {:ok, %Response{} = response} = Claude.chat(request())
    assert response.text == ~s({"do": "wait"})
    assert response.stop_reason == "end_turn"
    assert response.usage == %{"input_tokens" => 42, "output_tokens" => 7}
  end

  test "omits the system block when the request has none" do
    Req.Test.stub(Claude, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(raw), "system")

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    assert {:ok, %Response{text: "ok"}} = Claude.chat(request(system: nil))
  end

  test "renders block content with a cache breakpoint on flagged blocks" do
    Req.Test.stub(Claude, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [%{"role" => "user", "content" => [first, second, third]}] = body["messages"]
      assert %{"type" => "text", "text" => "beat one\n"} = first
      refute Map.has_key?(first, "cache_control")
      assert %{"text" => "beat two\n", "cache_control" => %{"type" => "ephemeral"}} = second
      refute Map.has_key?(third, "cache_control")

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    request =
      request(
        messages: [
          %{
            role: :user,
            content: [
              %{text: "beat one\n", cache: false},
              %{text: "beat two\n", cache: true},
              %{text: "your move", cache: false}
            ]
          }
        ]
      )

    assert {:ok, %Response{text: "ok"}} = Claude.chat(request)
  end

  test "folds a run of same-role messages into one — Anthropic requires alternating turns" do
    Req.Test.stub(Claude, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [%{"role" => "user", "content" => [beat_one, beat_two, instruction]}] =
               body["messages"]

      assert %{"type" => "text", "text" => "The player: Who's there?\n"} = beat_one
      refute Map.has_key?(beat_one, "cache_control")

      assert %{"text" => "Maren: Only me.\n", "cache_control" => %{"type" => "ephemeral"}} =
               beat_two

      assert %{"type" => "text", "text" => "Your move."} = instruction

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    request =
      request(
        messages: [
          %{role: :user, content: [%{text: "The player: Who's there?\n", cache: false}]},
          %{role: :user, content: [%{text: "Maren: Only me.\n", cache: true}]},
          %{role: :user, content: "Your move."}
        ]
      )

    assert {:ok, %Response{text: "ok"}} = Claude.chat(request)
  end

  test "sends the temperature only when one is set" do
    Req.Test.stub(Claude, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["temperature"] == 0.9

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    assert {:ok, _response} = Claude.chat(request(temperature: 0.9))

    Req.Test.stub(Claude, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(raw), "temperature")

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
    end)

    assert {:ok, _response} = Claude.chat(request())
  end

  test "joins multiple text blocks and ignores other block types" do
    Req.Test.stub(Claude, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{"type" => "thinking", "thinking" => ""},
          %{"type" => "text", "text" => "first"},
          %{"type" => "text", "text" => "second"}
        ]
      })
    end)

    assert {:ok, %Response{text: "first\nsecond"}} = Claude.chat(request())
  end

  test "returns an error tuple for non-200 responses" do
    Req.Test.stub(Claude, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error": {"type": "invalid_request_error"}}))
    end)

    assert {:error, {:http_error, 400, %{"error" => _}}} = Claude.chat(request())
  end

  test "returns an error tuple when the transport fails" do
    Req.Test.stub(Claude, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Claude.chat(request())
  end
end
