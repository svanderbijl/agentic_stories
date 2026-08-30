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

  describe "tableau/4" do
    # The plate must carry the moment's feeling, not just its furniture — but
    # only as a camera could catch it: on faces, in postures. The old prompt
    # banned "names of emotions" outright and every plate came out placid.
    test "asks the illustrator's eye for faces and the feeling the record left on them" do
      capture_request("CAPTION: The stranger turns away\nMaren stands at the rail, jaw set.")

      cast = [%Character{name: "Maren", persona: "a fisherwoman"}]

      beats = [
        %Message{
          kind: :say,
          content: ~s("Get out," she says.),
          character: %Character{name: "Maren"}
        }
      ]

      assert {:ok, scene, caption, []} = Narrator.tableau(story(), shore(), cast, beats)
      assert scene == "Maren stands at the rail, jaw set."
      assert caption == "The stranger turns away"

      assert_received {:request, request}
      assert request.system =~ "each FACE shows"
      assert request.system =~ "feeling"
      assert request.system =~ "never into the lens"
      assert request.system =~ "LOOKS:"
      refute request.system =~ "no names of emotions"
    end

    test "reads a LOOKS list so the engine can remember the clothes" do
      capture_request("""
      CAPTION: Changed
      LOOKS:
      - Maren: dark braid, red silk dress, the coat gone
      - the player: shirtsleeves

      Maren in a red silk dress, the coat on the floor.
      """)

      assert {:ok, scene, "Changed", looks} =
               Narrator.tableau(story(), shore(), [%Character{name: "Maren"}], [])

      assert scene =~ "red silk dress"

      assert looks == [
               {"Maren", "dark braid, red silk dress, the coat gone"},
               {"the player", "shirtsleeves"}
             ]
    end

    test "the looks it is given are current; the record's clothes still win if newer" do
      capture_request("CAPTION: Changed\nMaren in a red silk dress, the coat on the floor.")

      told =
        struct!(story(),
          protagonist: "Jack, salt in his hair, the keeper's coat still on."
        )

      cast = [
        %Character{
          name: "Maren",
          persona: "a fisherwoman",
          appearance: "Wind-burned, dark braid, a red silk dress."
        }
      ]

      beats = [
        %Message{
          kind: :act,
          content: "steps out of the coat and into a red silk dress",
          character: %Character{name: "Maren"}
        }
      ]

      assert {:ok, scene, _caption, _looks} = Narrator.tableau(told, shore(), cast, beats)
      assert scene =~ "red silk dress"

      assert_received {:request, request}
      assert request.system =~ "WEARING"
      assert request.system =~ "look NOW"
      assert hd(request.messages).content =~ "the player: Jack, salt in his hair"
      assert hd(request.messages).content =~ "Maren: Wind-burned, dark braid, a red silk dress."
      assert hd(request.messages).content =~ "red silk dress"
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

  describe "implied_departure/4" do
    defp maren(location_id \\ 1) do
      %Character{id: 7, name: "Maren", persona: "The sister.", location_id: location_id}
    end

    test "a beat that narrates following the player resolves to the place" do
      capture_request("The Porch")

      assert {:ok, %Location{name: "The Porch"}} =
               Narrator.implied_departure(
                 story(),
                 maren(),
                 locations(),
                 "Maren follows him out onto the porch, her boots loud on the boards."
               )

      assert_received {:request, request}
      assert request.system =~ "Maren"
      assert request.system =~ "The Porch"
    end

    test "a beat that names no other place never calls the model" do
      # verify_on_exit! would flag a call; the prefilter must catch this
      assert :none =
               Narrator.implied_departure(
                 story(),
                 maren(),
                 locations(),
                 "Maren shrugs and pours herself a drink."
               )
    end

    test "the place the character is already standing in is not a departure" do
      assert :none =
               Narrator.implied_departure(
                 story(),
                 maren(2),
                 locations(),
                 "Maren settles onto the porch bench without a word."
               )
    end

    test "a place named without going there is not a departure" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "NOTHING"}} end)

      assert :none =
               Narrator.implied_departure(
                 story(),
                 maren(),
                 locations(),
                 ~s(Maren looks toward the porch. "He'll be out there till dawn.")
               )
    end

    test "unknown places and failures collapse to :none" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "The Moon"}} end)
      assert :none = Narrator.implied_departure(story(), maren(), locations(), "off to the porch")

      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :none = Narrator.implied_departure(story(), maren(), locations(), "off to the porch")
    end

    test "a character with no location, or a story with no other place, never calls the model" do
      assert :none =
               Narrator.implied_departure(story(), maren(nil), locations(), "off to the porch")

      assert :none =
               Narrator.implied_departure(story(), maren(), [hd(locations())], "to the porch")
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
