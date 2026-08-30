defmodule AgenticStories.Engine.CharacterMindTest do
  use ExUnit.Case, async: true

  import Mox

  alias AgenticStories.Engine.CharacterMind
  alias AgenticStories.LLM
  alias AgenticStories.LLM.{Request, Response}
  alias AgenticStories.Stories.{Character, CharacterMemory, Location, Message, Story}

  setup :verify_on_exit!

  defp story do
    %Story{
      id: 1,
      title: "The Door Below",
      premise: "A keeper finds a door on the seabed.",
      tone: "quietly ominous",
      style: "Spare prose.",
      status: :live
    }
  end

  defp character do
    %Character{
      id: 1,
      name: "Maren",
      persona: "The keeper's sister.",
      voice: "Clipped.",
      location_id: 11
    }
  end

  defp locations do
    [
      %Location{id: 11, name: "The Lamp Room", description: "Hot brass."},
      %Location{id: 12, name: "The Shore", description: "Wet shingle."}
    ]
  end

  # decide/6 rescues every exception, so assertions must NEVER live inside
  # the mock (a failed assert would be swallowed into :wait and the test
  # would silently pass). Capture the request; assert in the test process.
  defp capture_request(response_text) do
    test_pid = self()

    expect(LLM.Mock, :chat, fn %Request{} = request ->
      send(test_pid, {:request, request})
      {:ok, %Response{text: response_text}}
    end)
  end

  describe "decide/6" do
    test "asks the character model in persona and returns the parsed decision" do
      maren = character()

      messages = [
        %Message{id: 1, kind: :player, content: "Who's there?", character: nil},
        %Message{id: 2, kind: :say, content: "The wind, probably.", character: maren}
      ]

      capture_request(~s(She lifts the lamp. "Only me."))

      assert {:say, ~s(She lifts the lamp. "Only me.")} =
               CharacterMind.decide(story(), character(), [], messages, locations())

      assert_received {:request, request}
      assert request.model == LLM.character_model()
      assert request.temperature == LLM.character_temperature()
      # everything static — persona, places, and the decision format —
      # lives in the cacheable system prompt
      assert request.system =~ "You are Maren"
      assert request.system =~ "The keeper's sister."
      assert request.system =~ "The Lamp Room: Hot brass."
      assert request.system =~ "-> The Shore: she takes the stairs"
      assert request.system =~ "write the single word: silence"
      # the story is told about them, not by them
      assert request.system =~ "third person"
      # the tick asks for prose, never for JSON
      refute request.system =~ ~s({"do":)

      # each beat is its own user message, breakpoint on the newest beat,
      # with only the volatile instruction message after it
      assert Enum.all?(request.messages, &(&1.role == :user))
      {transcript, [%{content: [instruction]}]} = Enum.split(request.messages, -1)

      assert Enum.map(transcript, fn %{content: [block]} -> block.text end) == [
               "The player: Who's there?\n",
               "Maren: The wind, probably.\n"
             ]

      assert Enum.map(transcript, fn %{content: [block]} -> block.cache end) == [false, true]
      assert instruction.cache == false
      assert instruction.text =~ "You are at: The Lamp Room."
      assert instruction.text =~ "The player last spoke 1 beats ago."
      assert instruction.text =~ "you, Maren"
    end

    test "keeps agenda and arc private but present, and carries a nudge" do
      minded =
        struct!(character(),
          agenda: "She has already been through the door.",
          arc: "From gatekeeper to confessor.",
          nudge: "Say it now."
        )

      messages = [%Message{id: 1, kind: :say, content: "Storm's coming.", character: character()}]

      capture_request("silence")
      assert :wait = CharacterMind.decide(story(), minded, [], messages, locations())

      assert_received {:request, request}
      assert request.system =~ "She has already been through the door."
      assert request.system =~ "never state it outright"
      assert request.system =~ "From gatekeeper to confessor."
      assert request.system =~ "let it pull you forward"

      assert %{content: [instruction]} = List.last(request.messages)
      assert instruction.text =~ "Say it now."
    end

    test "says who the player is, how this character enters, and who else is in the cast" do
      elsewhere = %Character{
        id: 2,
        name: "Old Tosk",
        persona: "A retired diver.",
        agenda: "He cut the rope himself."
      }

      arriving =
        struct!(character(),
          appearance: "Tall, city clothes, wrong shoes for shingle.",
          entrance: "You are the woman walking up from the tideline."
        )

      told = struct!(story(), protagonist: "Jack, who keeps the light and lives alone.")

      capture_request("silence")

      assert :wait =
               CharacterMind.decide(told, arriving, [], [], locations(),
                 cast: [arriving, elsewhere]
               )

      assert_received {:request, request}

      # who the player is, and that their body is not this character's to write
      assert request.system =~ "Jack, who keeps the light"
      assert request.system =~ "never write their beats"

      # which figure in the opening narration this character is
      assert request.system =~ "You are the woman walking up from the tideline."
      assert request.system =~ "Tall, city clothes"

      # the rest of the cast, by name — and never themselves
      assert request.system =~ "Old Tosk: A retired diver."
      refute request.system =~ "- Maren:"

      # another character's agenda is theirs alone
      refute request.system =~ "He cut the rope himself."
    end

    test "a story woven before protagonists and entrances still builds a prompt" do
      capture_request("silence")
      assert :wait = CharacterMind.decide(story(), character(), [], [], locations())

      assert_received {:request, request}
      assert request.system =~ "You are Maren"
      refute request.system =~ "The player is"
      refute request.system =~ "The others in this story"
    end

    test "a directly addressed character is told silence is not an option" do
      messages = [%Message{id: 1, kind: :player, content: "Maren, what is it?", character: nil}]

      capture_request("silence")
      assert :wait = CharacterMind.decide(story(), character(), [], messages, locations())

      assert_received {:request, request}
      assert %{content: [instruction]} = List.last(request.messages)
      assert instruction.text =~ "talking to YOU, directly"
      assert instruction.text =~ "Waiting is not"
    end

    test "alone with the player, every player beat is addressed to you" do
      # no name mentioned — but nobody else is in the room
      messages = [%Message{id: 1, kind: :player, content: "So. Tell me.", character: nil}]

      capture_request("silence")

      assert :wait =
               CharacterMind.decide(story(), character(), [], messages, locations(),
                 alone_with_player?: true
               )

      assert_received {:request, request}
      assert %{content: [instruction]} = List.last(request.messages)
      assert instruction.text =~ "talking to YOU, directly"
    end

    test "frozen memory blocks lead the content, breakpointed, never in the system prompt" do
      memories = [
        %CharacterMemory{id: 1, content: "The door was not on my lists."},
        %CharacterMemory{id: 2, content: "He went down to it anyway."}
      ]

      messages = [%Message{id: 9, kind: :player, content: "Still here?", character: nil}]

      capture_request("silence")
      assert :wait = CharacterMind.decide(story(), character(), memories, messages, locations())

      assert_received {:request, request}
      refute request.system =~ "The door was not on my lists."

      assert [memory, beat_message, _instruction] = request.messages
      assert [header, first, second] = memory.content

      assert header.text =~ "What you remember from earlier"
      assert first.text =~ "The door was not on my lists."
      assert second.text =~ "He went down to it anyway."
      # the chain ends in a breakpoint so the whole prefix is reusable
      assert first.cache == false
      assert second.cache == true

      assert [beat] = beat_message.content
      assert beat.text == "The player: Still here?\n"
      assert beat.cache == true
    end

    test "collapses provider errors to :wait" do
      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :wait = CharacterMind.decide(story(), character(), [], [], locations())
    end

    test "an empty reply is a wait; any other prose is simply their line" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "   "}} end)
      assert :wait = CharacterMind.decide(story(), character(), [], [], locations())

      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "hmm, tricky"}} end)

      assert {:act, "hmm, tricky"} =
               CharacterMind.decide(story(), character(), [], [], locations())
    end

    test "a half-formed decision object never spills braces into the story" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: ~s({"do": "shout"})}} end)
      assert :wait = CharacterMind.decide(story(), character(), [], [], locations())
    end

    @tag capture_log: true
    test "collapses even a raised exception to :wait — characters never crash a story" do
      expect(LLM.Mock, :chat, fn _request -> raise "ANTHROPIC_API_KEY is not set" end)
      assert :wait = CharacterMind.decide(story(), character(), [], [], locations())
    end
  end

  describe "directly_addressed?/3" do
    test "the newest witnessed beat must be the player's, and meant for you" do
      maren = character()
      named = %Message{id: 1, kind: :player, content: "Maren, what is it?", character_id: nil}
      unnamed = %Message{id: 2, kind: :player, content: "So. Tell me.", character_id: nil}
      deed = %Message{id: 3, kind: :act, content: "offers Maren the wrench", character_id: nil}
      reply = %Message{id: 4, kind: :say, content: "Only me.", character_id: 1}

      assert CharacterMind.directly_addressed?(maren, [named], false)
      assert CharacterMind.directly_addressed?(maren, [unnamed], true)
      assert CharacterMind.directly_addressed?(maren, [deed], false)
      refute CharacterMind.directly_addressed?(maren, [unnamed], false)
      # once anyone has answered, the obligation clears
      refute CharacterMind.directly_addressed?(maren, [named, reply], true)
      refute CharacterMind.directly_addressed?(maren, [], true)
    end
  end

  describe "consolidate/4" do
    test "writes the next journal entry, with earlier entries as context only" do
      memories = [%CharacterMemory{id: 1, content: "The door was not on my lists."}]
      beats = [%Message{kind: :player, content: "Who's there?", character: nil}]

      capture_request("  Someone came asking after the door tonight.  ")

      assert {:ok, "Someone came asking after the door tonight."} =
               CharacterMind.consolidate(story(), character(), memories, beats)

      assert_received {:request, request}
      assert request.system =~ "You are Maren"
      assert request.system =~ "plain prose only"
      assert [%{role: :user, content: content}] = request.messages
      assert content =~ "The door was not on my lists."
      assert content =~ "do not restate them"
      assert content =~ "The player: Who's there?"
      assert content =~ "Write the NEXT entry only"
    end

    test "collapses blank or failed responses to :error" do
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "   "}} end)
      assert :error = CharacterMind.consolidate(story(), character(), [], [])

      expect(LLM.Mock, :chat, fn _request -> {:error, :timeout} end)
      assert :error = CharacterMind.consolidate(story(), character(), [], [])
    end
  end

  describe "parse_decision/2" do
    test "quoted speech inside the prose makes it a spoken beat" do
      spoken = ~s(She takes the beer but doesn't open it. "I'm looking for something.")

      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision(spoken)

      # typographic quotes count too
      assert {:ok, {:say, _}} =
               CharacterMind.parse_decision("She sets it down. \u201CSuit yourself.\u201D")

      # models keep the transcript's own shape; it is their beat either way
      assert {:ok, {:say, ^spoken}} =
               CharacterMind.parse_decision("Maren: " <> spoken, "Maren")

      # the reading pane draws its own dialogue dash
      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision("— " <> spoken, "Maren")

      # dash and name arrive framed together, in either order and either dash
      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision("- Maren: " <> spoken, "Maren")
      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision("-Maren: " <> spoken, "Maren")
      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision("— Maren: " <> spoken, "Maren")
      assert {:ok, {:say, ^spoken}} = CharacterMind.parse_decision("Maren: — " <> spoken, "Maren")

      # a colon that is part of the beat survives
      assert {:ok, {:say, ~s(She turns. "Listen: I told you already.")}} =
               CharacterMind.parse_decision(~s(She turns. "Listen: I told you already."), "Maren")
    end

    test "a stripped leading dash never eats the move arrow" do
      assert {:ok, {:move, "The Shore", "she takes the stairs"}} =
               CharacterMind.parse_decision("-> The Shore: she takes the stairs", "Maren")
    end

    test "prose with nothing spoken is an act" do
      assert {:ok, {:act, "She picks up the rope and coils it."}} =
               CharacterMind.parse_decision("She picks up the rope and coils it.")

      # a single stray mark is punctuation, not speech
      assert {:ok, {:act, ~s(She measures it at 6" and frowns.)}} =
               CharacterMind.parse_decision(~s(She measures it at 6" and frowns.))
    end

    test "a wholly asterisked line is still an act" do
      assert {:ok, {:act, "picks up the rope"}} =
               CharacterMind.parse_decision("*picks up the rope*")

      assert {:ok, {:act, "picks up the rope"}} =
               CharacterMind.parse_decision("Maren: *picks up the rope*", "Maren")
    end

    test "an arrow line is a move" do
      assert {:ok, {:move, "The Shore", "heads down the stairs"}} =
               CharacterMind.parse_decision("-> The Shore: heads down the stairs")

      assert {:ok, {:move, "The Shore", "heads down"}} =
               CharacterMind.parse_decision("→ The Shore: heads down")

      assert {:ok, {:move, "The Shore", nil}} = CharacterMind.parse_decision("-> The Shore")
    end

    # A model deep in its prose writes the paragraphs first and the arrow
    # where the walking happens — the reply is still a departure, the prose
    # around the arrow is the beat, and the marker itself never reaches the
    # story as literal text.
    test "an arrow after prose is still a move, and the prose is the beat" do
      reply = """
      She sets her drink down on the dresser.

      "Don't wake me up early."

      -> The Ranch House: She lingers at the doorway of the guest room.
      """

      assert {:ok, {:move, "The Ranch House", text}} = CharacterMind.parse_decision(reply)
      assert text =~ "sets her drink down"
      assert text =~ "Don't wake me up early"
      assert text =~ "She lingers at the doorway"
      refute text =~ "->"
      refute text =~ "The Ranch House"
    end

    test "prose on both sides of the arrow line stays in the beat" do
      reply =
        ~s("I'm not running. I'm just moving."\n\n-> The Shore\n\nShe doesn't stop until they reach the water.)

      assert {:ok, {:move, "The Shore", text}} = CharacterMind.parse_decision(reply)
      assert text =~ "I'm not running"
      assert text =~ "reach the water"
      refute text =~ "->"
    end

    test "silence and an empty reply are both a wait" do
      assert {:ok, :wait} = CharacterMind.parse_decision("silence")
      assert {:ok, :wait} = CharacterMind.parse_decision("Silence")
      assert {:ok, :wait} = CharacterMind.parse_decision("   ")
      assert {:ok, :wait} = CharacterMind.parse_decision("Maren:", "Maren")
    end

    test "a model that reaches for JSON anyway is still understood" do
      assert {:ok, {:say, "Hello."}} =
               CharacterMind.parse_decision(~s({"do": "say", "text": "Hello."}))

      assert {:ok, {:act, "picks up the rope"}} =
               CharacterMind.parse_decision(~s({"do": "act", "text": "picks up the rope"}))

      assert {:ok, :wait} = CharacterMind.parse_decision(~s({"do": "wait"}))

      assert {:ok, {:move, "The Shore", "heads down the stairs"}} =
               CharacterMind.parse_decision(
                 ~s({"do": "move", "to": "The Shore", "text": "heads down the stairs"})
               )

      # braces are never allowed to spill into the story
      assert :error = CharacterMind.parse_decision(~s({"do": "shout"}))
      assert :error = CharacterMind.parse_decision(~s({"do": "say", "text": ""}))
    end
  end

  describe "repetitive?/2" do
    test "flags near-verbatim repeats of the character's own recent lines" do
      maren = %Character{id: 1, name: "Maren"}

      messages = [
        %Message{kind: :say, content: "The sea keeps what it likes.", character_id: 1},
        %Message{kind: :player, content: "What?", character_id: nil}
      ]

      assert CharacterMind.repetitive?(maren, "The sea keeps what it likes.", messages)
      assert CharacterMind.repetitive?(maren, "The sea keeps what it likes!", messages)
      refute CharacterMind.repetitive?(maren, "The door was not on my lists.", messages)
      # another character's line is fair game
      other = %Character{id: 2, name: "Old Tosk"}
      refute CharacterMind.repetitive?(other, "The sea keeps what it likes.", messages)
    end
  end

  describe "beats_since_player/1" do
    test "counts beats back to the player's last message" do
      maren = %Character{name: "Maren"}
      player = %Message{kind: :player, content: "Hello?", character: nil}
      say = %Message{kind: :say, content: "Hm.", character: maren}

      assert CharacterMind.beats_since_player([player]) == 0
      assert CharacterMind.beats_since_player([player, say, say]) == 2
      assert CharacterMind.beats_since_player([say, player, say]) == 1
      assert CharacterMind.beats_since_player([say, say]) == :never
      assert CharacterMind.beats_since_player([]) == :never
    end
  end

  describe "transcript/1" do
    test "renders each message kind as a script line" do
      maren = %Character{name: "Maren"}

      messages = [
        %Message{kind: :narration, content: "The tide pulls back.", character: nil},
        %Message{kind: :player, content: "Hello?", character: nil},
        %Message{kind: :say, content: "Only me.", character: maren},
        %Message{kind: :act, content: "lights the lamp", character: maren}
      ]

      assert CharacterMind.transcript(messages) ==
               """
               Narrator: The tide pulls back.
               The player: Hello?
               Maren: Only me.
               * Maren lights the lamp\
               """
    end

    test "a witnessed illustration reads as its caption — never a crash" do
      messages = [
        %Message{kind: :illustration, content: "The door, ajar.", character: nil}
      ]

      assert CharacterMind.transcript(messages) == "Narrator: The door, ajar."
    end
  end
end
