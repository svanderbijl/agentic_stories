defmodule AgenticStories.LLM.GrokTest do
  use ExUnit.Case, async: true

  alias AgenticStories.LLM.{Grok, Request, Response}

  defp request(attrs \\ []) do
    struct!(
      %Request{
        model: "grok-4.3",
        system: "You are Maren.",
        messages: [%{role: :user, content: "Your move."}],
        max_tokens: 1024
      },
      attrs
    )
  end

  test "posts an OpenAI-compatible request to /v1/chat/completions" do
    Req.Test.stub(Grok, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/chat/completions"
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert body["model"] == "grok-4.3"
      assert body["max_tokens"] == 1024

      assert [
               %{"role" => "system", "content" => "You are Maren."},
               %{"role" => "user", "content" => "Your move."}
             ] = body["messages"]

      Req.Test.json(conn, %{
        "model" => "grok-4.3",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => ~s({"do": "wait"})},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 42,
          "completion_tokens" => 7,
          "prompt_tokens_details" => %{"cached_tokens" => 30}
        }
      })
    end)

    assert {:ok, %Response{} = response} = Grok.chat(request())
    assert response.text == ~s({"do": "wait"})
    assert response.stop_reason == "stop"
    assert response.usage["prompt_tokens"] == 42
  end

  test "flattens block content into one string — xAI caching is automatic" do
    Req.Test.stub(Grok, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [_system, %{"role" => "user", "content" => "beat one\nbeat two\ngo"}] =
               body["messages"]

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    request =
      request(
        messages: [
          %{
            role: :user,
            content: [
              %{text: "beat one\n", cache: false},
              %{text: "beat two\n", cache: true},
              %{text: "go", cache: false}
            ]
          }
        ]
      )

    assert {:ok, %Response{text: "ok"}} = Grok.chat(request)
  end

  test "folds a run of same-role messages into one turn, flattened in order" do
    Req.Test.stub(Grok, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [
               _system,
               %{
                 "role" => "user",
                 "content" => "The player: Who's there?\nMaren: Only me.\nYour move."
               }
             ] = body["messages"]

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    request =
      request(
        messages: [
          %{role: :user, content: [%{text: "The player: Who's there?\n", cache: false}]},
          %{role: :user, content: [%{text: "Maren: Only me.\n", cache: true}]},
          %{role: :user, content: "Your move."}
        ]
      )

    assert {:ok, %Response{text: "ok"}} = Grok.chat(request)
  end

  test "omits the system message when the request has none" do
    Req.Test.stub(Grok, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert [%{"role" => "user"}] = Jason.decode!(raw)["messages"]
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    assert {:ok, %Response{text: "ok"}} = Grok.chat(request(system: nil))
  end

  test "returns an error tuple for non-200 responses" do
    Req.Test.stub(Grok, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, ~s({"error": "rate limited"}))
    end)

    assert {:error, {:http_error, 429, _body}} = Grok.chat(request())
  end
end
