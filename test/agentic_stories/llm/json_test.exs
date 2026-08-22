defmodule AgenticStories.LLM.JSONTest do
  use ExUnit.Case, async: true

  alias AgenticStories.LLM.JSON

  describe "decode_object/1" do
    test "decodes a bare JSON object" do
      assert {:ok, %{"do" => "wait"}} = JSON.decode_object(~s({"do": "wait"}))
    end

    test "decodes an object wrapped in code fences" do
      text = """
      ```json
      {"do": "say", "text": "Hello."}
      ```
      """

      assert {:ok, %{"do" => "say", "text" => "Hello."}} = JSON.decode_object(text)
    end

    test "decodes an object surrounded by prose" do
      text = ~s(Here is my decision: {"do": "wait"} — I have nothing to add.)
      assert {:ok, %{"do" => "wait"}} = JSON.decode_object(text)
    end

    test "handles nested objects" do
      text = ~s({"characters": [{"name": "Maren"}]})
      assert {:ok, %{"characters" => [%{"name" => "Maren"}]}} = JSON.decode_object(text)
    end

    test "returns :error when there is no object" do
      assert :error = JSON.decode_object("I would rather stay quiet.")
      assert :error = JSON.decode_object("")
    end

    test "returns :error for malformed JSON" do
      assert :error = JSON.decode_object(~s({"do": "say", "text": ))
    end

    test "returns :error when braces are out of order" do
      assert :error = JSON.decode_object("} nothing here {")
    end
  end
end
