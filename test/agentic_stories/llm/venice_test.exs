defmodule AgenticStories.LLM.VeniceTest do
  use ExUnit.Case, async: true

  alias AgenticStories.LLM.{Request, Response, Venice}

  defp request(attrs \\ []) do
    struct!(
      %Request{
        model: "venice-uncensored-1-2",
        system: "You are Maren.",
        messages: [%{role: :user, content: "Your move."}],
        max_tokens: 1024
      },
      attrs
    )
  end

  test "posts an OpenAI-compatible request with Venice's system prompt disabled" do
    Req.Test.stub(Venice, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/chat/completions"
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert body["model"] == "venice-uncensored-1-2"
      assert body["max_tokens"] == 1024

      # Venice would otherwise prepend its own system prompt to every persona;
      # thinking is stripped so reasoning models return clean JSON.
      assert body["venice_parameters"] == %{
               "include_venice_system_prompt" => false,
               "strip_thinking_response" => true
             }

      assert [
               %{
                 "role" => "system",
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "You are Maren.",
                     "cache_control" => %{"type" => "ephemeral"}
                   }
                 ]
               },
               %{"role" => "user", "content" => "Your move."}
             ] = body["messages"]

      Req.Test.json(conn, %{
        "model" => "venice-uncensored-1-2",
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

    assert {:ok, %Response{} = response} = Venice.chat(request())
    assert response.text == ~s({"do": "wait"})
    assert response.stop_reason == "stop"
    assert response.usage["prompt_tokens"] == 42
    assert get_in(response.usage, ["prompt_tokens_details", "cached_tokens"]) == 30
  end

  test "renders blocks as text parts, cache: true as a cache_control breakpoint" do
    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [
               _system,
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "beat one\n"} = plain,
                   %{
                     "type" => "text",
                     "text" => "beat two\n",
                     "cache_control" => %{"type" => "ephemeral"}
                   },
                   %{"type" => "text", "text" => "go"}
                 ]
               }
             ] = body["messages"]

      refute Map.has_key?(plain, "cache_control")

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

    assert {:ok, %Response{text: "ok"}} = Venice.chat(request)
  end

  test "omits the system message when the request has none" do
    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert [%{"role" => "user"}] = Jason.decode!(raw)["messages"]
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    assert {:ok, %Response{text: "ok"}} = Venice.chat(request(system: nil))
  end

  test "returns an error tuple for non-200 responses" do
    Req.Test.stub(Venice, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, ~s({"error": "rate limited"}))
    end)

    assert {:error, {:http_error, 429, _body}} = Venice.chat(request())
  end
end
