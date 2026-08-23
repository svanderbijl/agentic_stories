defmodule AgenticStories.Engine.DirectorMindTest do
  use ExUnit.Case, async: true

  import Mox

  alias AgenticStories.Engine.DirectorMind
  alias AgenticStories.LLM
  alias AgenticStories.LLM.{Request, Response}
  alias AgenticStories.Stories.{Character, Location, Message, Story}

  setup :verify_on_exit!

  defp story do
    %Story{
      id: 1,
      title: "The Door Below",
      premise: "A keeper finds a door on the seabed.",
      arc: "Down, through, and changed.",
      tone: "quietly ominous",
      style: "Spare prose.",
      status: :live,
      player_location_id: 11
    }
  end

  defp locations do
    [
      %Location{id: 11, name: "The Lamp Room", description: "Hot brass."},
      %Location{id: 12, name: "The Shore", description: "Wet shingle."}
    ]
  end

  defp characters do
    [
      %Character{
        id: 1,
        name: "Maren",
        persona: "The keeper's sister.",
        agenda: "She has already been through the door.",
        location_id: 11
      }
    ]
  end

  describe "decide/4" do
    # decide rescues everything, so assertions must not live inside the mock
    # (a failed assert would be swallowed into :wait). Capture, then assert.
    test "sees everything: agendas, places, and beats from every location" do
      beats = [
        %Message{id: 1, kind: :player, content: "Hello?", character: nil, location_id: 11},
        %Message{
          id: 2,
          kind: :act,
          content: "digs at the tideline",
          character: %Character{name: "Old Tosk"},
          character_id: 99,
          location_id: 12
        }
      ]

      test_pid = self()

      expect(LLM.Mock, :chat, fn %Request{} = request ->
        send(test_pid, {:request, request})
        {:ok, %Response{text: ~s({"do": "wait"})}}
      end)

      assert :wait = DirectorMind.decide(story(), characters(), locations(), beats)

      assert_received {:request, request}
      assert request.model == LLM.director_model()
      assert request.system =~ "Director"
      assert request.system =~ "She has already been through the door."
      assert request.system =~ "The Shore: Wet shingle."
      assert [%{role: :user, content: content}] = request.messages
      assert content =~ "[The Lamp Room] The player: Hello?"
      assert content =~ "[The Shore] * Old Tosk digs at the tideline"
      assert content =~ "The player is at: The Lamp Room."
      # the newest beat is a character's, so nothing is unanswered
      refute content =~ "gone unanswered"
    end

    test "flags the player's unanswered beats" do
      beats = [
        %Message{id: 1, kind: :player, content: "Hello?", character: nil, location_id: 11},
        %Message{id: 2, kind: :act, content: "waits by the gate", character: nil, location_id: 11}
      ]

      test_pid = self()

      expect(LLM.Mock, :chat, fn request ->
        send(test_pid, {:request, request})
        {:ok, %Response{text: ~s({"do": "wait"})}}
      end)

      assert :wait = DirectorMind.decide(story(), characters(), locations(), beats)

      assert_received {:request, request}
      assert [%{role: :user, content: content}] = request.messages
      assert content =~ "last 2 beat(s) have gone unanswered"
    end

    test "collapses errors and nonsense to :wait" do
      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :wait = DirectorMind.decide(story(), characters(), locations(), [])

      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "hmm"}} end)
      assert :wait = DirectorMind.decide(story(), characters(), locations(), [])
    end
  end

  describe "parse_direction/1" do
    test "parses every direction" do
      assert {:ok, {:narrate, "The tide turns.", "The Shore"}} =
               DirectorMind.parse_direction(
                 ~s({"do": "narrate", "text": "The tide turns.", "location": "The Shore"})
               )

      assert {:ok, {:narrate, "Night falls.", nil}} =
               DirectorMind.parse_direction(~s({"do": "narrate", "text": "Night falls."}))

      assert {:ok, {:nudge, "Maren", "Tell them tonight."}} =
               DirectorMind.parse_direction(
                 ~s({"do": "nudge", "character": "Maren", "note": "Tell them tonight."})
               )

      assert {:ok, {:reveal, "Beyond the Door", "Dark water, lit from below."}} =
               DirectorMind.parse_direction(
                 ~s({"do": "reveal", "name": "Beyond the Door", "description": "Dark water, lit from below."})
               )

      assert {:ok, {:illustrate, "the door ajar", "The door, ajar."}} =
               DirectorMind.parse_direction(
                 ~s({"do": "illustrate", "prompt": "the door ajar", "caption": "The door, ajar."})
               )

      assert {:ok, {:move_character, "Maren", "The Shore", "slips back down to the water"}} =
               DirectorMind.parse_direction(
                 ~s({"do": "move", "character": "Maren", "to": "The Shore", "text": "slips back down to the water"})
               )

      assert {:ok, {:move_character, "Maren", "The Shore", nil}} =
               DirectorMind.parse_direction(
                 ~s({"do": "move", "character": "Maren", "to": "The Shore"})
               )

      assert {:ok, {:conclude, "And so it closed."}} =
               DirectorMind.parse_direction(~s({"do": "conclude", "text": "And so it closed."}))

      assert {:ok, :wait} = DirectorMind.parse_direction(~s({"do": "wait"}))
    end

    test "rejects malformed directions" do
      assert :error = DirectorMind.parse_direction(~s({"do": "narrate", "text": ""}))
      assert :error = DirectorMind.parse_direction(~s({"do": "nudge", "character": "Maren"}))
      assert :error = DirectorMind.parse_direction(~s({"do": "move", "character": "Maren"}))
      assert :error = DirectorMind.parse_direction("silence")
    end
  end
end
