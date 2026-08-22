defmodule AgenticStories.Engine.NarratorTest do
  use ExUnit.Case, async: true

  import Mox

  alias AgenticStories.Engine.Narrator
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Response
  alias AgenticStories.Stories.{Character, Location, Message, Story}

  setup :verify_on_exit!

  defp story do
    %Story{id: 1, title: "The Door Below", tone: "quietly ominous", style: "Spare prose."}
  end

  defp shore, do: %Location{id: 12, name: "The Shore", description: "Wet shingle."}

  defp missed do
    [
      %Message{
        kind: :act,
        content: "drags something up the shingle",
        character: %Character{name: "Old Tosk"}
      }
    ]
  end

  # Narrator functions rescue everything, so assertions must not live inside
  # the mock (a failed assert would be swallowed). Capture, then assert.
  defp capture_request(response_text) do
    test_pid = self()

    expect(LLM.Mock, :chat, fn request ->
      send(test_pid, {:request, request})
      {:ok, %Response{text: response_text}}
    end)
  end

  describe "residue/3" do
    test "turns missed beats into traces the arriving player notices" do
      capture_request("The shingle is churned in a long, deliberate furrow.")

      assert {:ok, "The shingle is churned" <> _rest} =
               Narrator.residue(story(), shore(), missed())

      assert_received {:request, request}
      assert request.system =~ "traces"
      assert [%{role: :user, content: content}] = request.messages
      assert content =~ "The Shore"
      assert content =~ "drags something up the shingle"
    end

    test "nothing missed means nothing to notice — without an LLM call" do
      assert :none = Narrator.residue(story(), shore(), [])
    end

    test "NOTHING and failures collapse to :none" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "NOTHING"}} end)
      assert :none = Narrator.residue(story(), shore(), missed())

      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :none = Narrator.residue(story(), shore(), missed())
    end
  end

  describe "implied_move/3" do
    defp locations do
      [
        %Location{id: 1, name: "The Ranch Gate", description: "Dust and chrome."},
        %Location{id: 2, name: "The Porch", description: "A bench and a bottle."}
      ]
    end

    test "resolves narrated movement to a place, tolerating punctuation" do
      capture_request("The Porch.\n")

      assert {:ok, %Location{name: "The Porch"}} =
               Narrator.implied_move(
                 story(),
                 locations(),
                 "You head for the porch and pour a whiskey"
               )

      assert_received {:request, request}
      assert request.system =~ "The Porch"

      assert [%{role: :user, content: "You head for the porch and pour a whiskey"}] =
               request.messages
    end

    test "stated intent is not movement" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "NOTHING"}} end)
      assert :none = Narrator.implied_move(story(), locations(), "Find me at the porch later.")
    end

    test "unknown places and failures collapse to :none" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "The Moon"}} end)
      assert :none = Narrator.implied_move(story(), locations(), "I fly to the moon")

      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :none = Narrator.implied_move(story(), locations(), "I walk off")
    end

    test "location-less stories never call the model" do
      assert :none = Narrator.implied_move(story(), [], "I head for the porch")
      assert :none = Narrator.implied_move(story(), [hd(locations())], "I head for the porch")
    end
  end

  describe "recap/2" do
    test "writes a second-person recap of witnessed beats" do
      beats = [%Message{kind: :player, content: "Hello?", character: nil}]

      capture_request("You called out into the lamplight, and someone answered.")

      assert {:ok, "You called out" <> _rest} = Narrator.recap(story(), beats)

      assert_received {:request, request}
      assert request.system =~ "recap"
    end

    test "no beats or failures collapse to :error" do
      assert :error = Narrator.recap(story(), [])

      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "  "}} end)

      assert :error =
               Narrator.recap(story(), [%Message{kind: :player, content: "Hi", character: nil}])
    end
  end
end
