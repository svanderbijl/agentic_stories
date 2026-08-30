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

  test "folds a run of same-role messages into one turn — a chat template wraps each message" do
    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      assert [_system, %{"role" => "user", "content" => [beat_one, beat_two, instruction]}] =
               body["messages"]

      assert %{"type" => "text", "text" => "The player: Who's there?\n"} = beat_one
      refute Map.has_key?(beat_one, "cache_control")

      assert %{"text" => "Maren: Only me.\n", "cache_control" => %{"type" => "ephemeral"}} =
               beat_two

      assert %{"type" => "text", "text" => "Your move."} = instruction

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

    assert {:ok, %Response{text: "ok"}} = Venice.chat(request)
  end

  test "sends the temperature only when one is set" do
    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["temperature"] == 1.0

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    assert {:ok, _response} = Venice.chat(request(temperature: 1.0))

    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(raw), "temperature")

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    assert {:ok, _response} = Venice.chat(request())
  end

  test "omits the system message when the request has none" do
    Req.Test.stub(Venice, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert [%{"role" => "user"}] = Jason.decode!(raw)["messages"]
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end)

    assert {:ok, %Response{text: "ok"}} = Venice.chat(request(system: nil))
  end

  # Venice's `strip_thinking_response` handles the well-formed case, but
  # reasoning models leak past it: Qwen-family templates can emit reasoning
  # with only a closing tag, and a response truncated mid-thought has no
  # final prose at all. Only what comes after the thinking may reach a story.
  describe "thinking that leaks past Venice's server-side strip" do
    defp respond_with(text) do
      Req.Test.stub(Venice, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => text}}]})
      end)
    end

    test "drops a well-formed <think> block" do
      respond_with("<think>She would hear it as a threat.</think>\nMaren sets down the cup.")

      assert {:ok, %Response{text: "Maren sets down the cup."}} = Venice.chat(request())
    end

    test "drops reasoning that arrives with only a closing tag" do
      respond_with("The player expects an answer.\n</think>\n\"Only me,\" Maren says.")

      assert {:ok, %Response{text: ~s("Only me," Maren says.)}} = Venice.chat(request())
    end

    test "a response truncated mid-thought is an empty reply, not leaked reasoning" do
      respond_with("<think>She weighs whether to admit she saw the light go out and")

      assert {:ok, %Response{text: ""}} = Venice.chat(request())
    end

    test "prose without thinking tags passes through byte-identical" do
      respond_with("  -> The Kitchen: Maren follows the smell of smoke.")

      assert {:ok, %Response{text: "  -> The Kitchen: Maren follows the smell of smoke."}} =
               Venice.chat(request())
    end
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
