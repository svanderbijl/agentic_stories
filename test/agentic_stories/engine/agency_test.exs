defmodule AgenticStories.Engine.AgencyTest do
  use ExUnit.Case, async: true

  alias AgenticStories.Engine.Agency
  alias AgenticStories.Stories.Character

  defp maren, do: %Character{id: 1, name: "Maren"}
  defp brahm, do: %Character{id: 2, name: "Brahm"}
  defp room, do: [maren(), brahm()]

  describe "classify/2" do
    test "talk, looking, and sitting are color" do
      assert :color = Agency.classify("Hello?", room())
      assert :color = Agency.classify("Maren, what do you know?", room())
      assert :color = Agency.classify("Hello, Maren.", room())
      assert :color = Agency.classify("I ask Maren about the door", room())
      assert :color = Agency.classify("I sit with Maren", room())
      assert :color = Agency.classify("I take a seat next to Maren", room())
      assert :color = Agency.classify("I give up, Maren", room())
      assert :color = Agency.classify("I confess, Maren", room())
      assert :color = Agency.classify("I grab a beer", [maren()])
      assert :color = Agency.classify("I shoot the lock", [maren()])
    end

    test "a name inside another word is not a person" do
      art = %Character{id: 3, name: "Art"}
      assert :color = Agency.classify("a fresh start", [art, maren()])
    end

    test "narrating what a named character does is a bid, in any language" do
      assert {:bid, [1]} =
               Agency.classify("Maren hands me the key and tells me everything", room())

      assert {:bid, [1]} = Agency.classify("Maren geeft me de sleutel", room())

      assert {:bid, [4]} =
               Agency.classify("Old Tosk hands me the lamp", [
                 %Character{id: 4, name: "Old Tosk"}
               ])
    end

    test "taking, kissing, or forcing a named person is a bid" do
      assert {:bid, [1]} = Agency.classify("I take the letter from Maren's pocket", room())
      assert {:bid, [1]} = Agency.classify("I take your letter, Maren", room())
      assert {:bid, [1]} = Agency.classify("I kiss Maren", room())
      assert {:bid, [1]} = Agency.classify("I shoot Maren", room())
      assert {:bid, [1]} = Agency.classify("I make Maren tell me", room())
      assert {:bid, [1]} = Agency.classify("I give Maren the key", room())
    end

    test "a pronoun lands on the only person present, and on nobody in a crowd" do
      assert {:bid, [1]} = Agency.classify("I kiss her", [maren()])
      assert {:bid, [1]} = Agency.classify("She confesses everything", [maren()])
      assert {:bid, [1]} = Agency.classify("Ik kus haar", [maren()])
      assert {:bid, [1]} = Agency.classify("Ik sla haar", [maren()])

      assert :color = Agency.classify("I kiss her", room())
      assert :color = Agency.classify("She confesses everything", room())
    end

    test "a line that narrates two people bids on both, in cast order" do
      assert {:bid, [1, 2]} = Agency.classify("Maren and Brahm drop their weapons", room())
    end
  end

  describe "focus/2" do
    test "a group hello is about no one; a name, or being alone, is" do
      assert {[], :color} = Agency.focus("Hello?", room())
      assert {[1], :color} = Agency.focus("Hello?", [maren()])
      assert {[1], :color} = Agency.focus("Maren, are you awake?", room())
    end

    test "a bid focuses its targets" do
      assert {[1], :bid} = Agency.focus("I take the key from Maren's pocket.", room())
    end
  end
end
