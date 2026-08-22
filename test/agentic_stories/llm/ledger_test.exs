defmodule AgenticStories.LLM.LedgerTest do
  use AgenticStories.DataCase, async: true

  import Mox

  alias AgenticStories.LLM
  alias AgenticStories.LLM.{Ledger, Request, Response}

  setup :verify_on_exit!

  defp request do
    %Request{model: "grok-4.3", messages: [%{role: :user, content: "hi"}]}
  end

  test "chat/2 records normalized Anthropic-shaped usage" do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok,
       %Response{
         text: "ok",
         usage: %{
           "input_tokens" => 100,
           "output_tokens" => 20,
           "cache_read_input_tokens" => 80
         }
       }}
    end)

    assert {:ok, _response} = LLM.chat(request(), story_id: 7, purpose: :tick)

    assert %{calls: 1, input_tokens: 100, output_tokens: 20, cached_tokens: 80} =
             Ledger.story_totals(7)
  end

  test "chat/2 records normalized OpenAI-shaped usage" do
    expect(LLM.Mock, :chat, fn _request ->
      {:ok,
       %Response{
         text: "ok",
         usage: %{
           "prompt_tokens" => 50,
           "completion_tokens" => 10,
           "prompt_tokens_details" => %{"cached_tokens" => 40}
         }
       }}
    end)

    assert {:ok, _response} = LLM.chat(request(), story_id: 8, purpose: :tick)

    assert %{calls: 1, input_tokens: 50, output_tokens: 10, cached_tokens: 40} =
             Ledger.story_totals(8)
  end

  test "totals sum across calls and missing usage counts as zero" do
    expect(LLM.Mock, :chat, 2, fn _request -> {:ok, %Response{text: "ok"}} end)

    assert {:ok, _} = LLM.chat(request(), story_id: 9, purpose: :tick)
    assert {:ok, _} = LLM.chat(request(), story_id: 9, purpose: :consolidate)

    assert %{calls: 2, input_tokens: 0, output_tokens: 0} = Ledger.story_totals(9)
  end
end
