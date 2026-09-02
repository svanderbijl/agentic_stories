defmodule AgenticStories.Engine.WeaverTest do
  use AgenticStories.DataCase, async: true

  import AgenticStories.StoriesFixtures
  import Mox

  alias AgenticStories.Engine.Weaver
  alias AgenticStories.Imagery
  alias AgenticStories.LLM
  alias AgenticStories.LLM.{Request, Response}
  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Character, Story}

  setup :verify_on_exit!

  @blueprint %{
    "title" => "The Door Below",
    "premise" => "A keeper finds a door on the seabed.",
    "protagonist" => "The keeper, who has tended this light for nine years.",
    "arc" => "Down, through, and changed.",
    "tone" => "quietly ominous",
    "style" => "Spare prose.",
    "opening" => "The tide pulls back further than it should.",
    "opening_location" => "The Shore",
    "locations" => [
      %{"name" => "The Lamp Room", "description" => "Hot brass and salt glass."},
      %{"name" => "The Shore", "description" => "Wet shingle, retreating water."}
    ],
    "characters" => [
      %{
        "name" => "Maren",
        "persona" => "The keeper's sister.",
        "voice" => "Clipped.",
        "agenda" => "She has already been through the door.",
        "arc" => "From gatekeeper to confessor.",
        "appearance" => "Wind-burned, dark braid, a coat two sizes too big.",
        "entrance" => "You are the woman walking up from the tideline.",
        "location" => "The Shore"
      },
      %{
        "name" => "Old Tosk",
        "persona" => "A retired diver.",
        "voice" => "Slow.",
        "appearance" => "Weathered, salt-white beard, oilskin coat.",
        "location" => "The Lamp Room"
      }
    ]
  }

  describe "weave/1" do
    test "asks the weaver model and brings the story live" do
      story = weaving_story_fixture()

      expect(LLM.Mock, :chat, fn %Request{} = request ->
        assert request.model == LLM.weaver_model()
        assert request.system =~ "Weaver"
        assert request.system =~ "If the seed describes how they look, copy that exactly"
        assert request.system =~ "a red dress in the seed is a"
        assert [%{role: :user, content: content}] = request.messages
        assert content =~ story.seed

        {:ok, %Response{text: Jason.encode!(@blueprint)}}
      end)

      assert {:ok, %Story{status: :live, title: "The Door Below"}} = Weaver.weave(story)

      characters = Stories.list_characters(story.id)
      assert Enum.map(characters, & &1.name) == ["Maren", "Old Tosk"]
      assert Enum.all?(characters, &(&1.energy == 2))

      assert [%{kind: :narration}] = Stories.list_messages(story.id)
    end

    test "marks the story failed when the provider errors" do
      story = weaving_story_fixture()
      expect(LLM.Mock, :chat, fn _request -> {:error, {:http_error, 500, %{}}} end)

      assert {:error, _reason} = Weaver.weave(story)
      assert %Story{status: :failed, failure_reason: reason} = Stories.get_story!(story.id)
      assert reason =~ "came apart"
    end

    test "marks the story failed when the blueprint is malformed" do
      story = weaving_story_fixture()
      expect(LLM.Mock, :chat, fn _request -> {:ok, %Response{text: "not even json"}} end)

      assert {:error, _reason} = Weaver.weave(story)
      assert %Story{status: :failed} = Stories.get_story!(story.id)
    end
  end

  describe "avatars" do
    test "paints a portrait per character once the weave completes" do
      config = Application.fetch_env!(:agentic_stories, Imagery)
      on_exit(fn -> Application.put_env(:agentic_stories, Imagery, config) end)
      Application.put_env(:agentic_stories, Imagery, Keyword.put(config, :enabled, true))

      story = weaving_story_fixture()
      Stories.subscribe(story.id)

      expect(LLM.Mock, :chat, fn _request ->
        {:ok, %Response{text: Jason.encode!(@blueprint)}}
      end)

      expect(Imagery.Mock, :generate, 3, fn prompt ->
        assert prompt =~ "portrait"
        assert prompt =~ "quietly ominous"
        {:ok, %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}}
      end)

      # A sheet per likeness (player + two characters), then the opening
      # plate composes around those sheets rather than racing them into
      # an empty room. The player leads (they are in every picture); Maren
      # is on The Shore; Old Tosk is up in the lamp room and stays out of it.
      expect(Imagery.Mock, :compose, 4, fn prompt, references ->
        if String.contains?(prompt, "CHARACTER SHEET LAYOUT") do
          assert length(references) == 1
          assert prompt =~ "exact visual identity"
        else
          assert [player, maren] = references
          assert player.content_type == "image/jpeg"
          assert maren.content_type == "image/jpeg"
          assert prompt =~ "source image 1: the player"
          assert prompt =~ "source image 2: Maren"
          refute prompt =~ "Old Tosk"
        end

        {:ok, %{binary: <<255, 216, 255>>, content_type: "image/jpeg"}}
      end)

      assert {:ok, %Story{}} = Weaver.weave(story)

      assert_receive {:character_updated, %Character{avatar_type: "image/jpeg"}}, 2_000
      assert_receive {:character_updated, %Character{avatar_type: "image/jpeg"}}, 2_000

      # the opening plate waits for every sheet, so it is the signal that
      # likeness compose has finished — portraits alone are not enough
      assert_receive {:message_created, %{kind: :illustration, content: "The Shore"}}, 2_000

      assert {<<255, 216, 255>>, "image/jpeg"} = Stories.get_player_board(story.id)

      assert story.id
             |> Stories.list_characters()
             |> Enum.all?(&is_binary(&1.board_type))
    end

    test "a failed portrait leaves the character unpainted and the story fine" do
      config = Application.fetch_env!(:agentic_stories, Imagery)
      on_exit(fn -> Application.put_env(:agentic_stories, Imagery, config) end)
      Application.put_env(:agentic_stories, Imagery, Keyword.put(config, :enabled, true))

      story = weaving_story_fixture()
      Stories.subscribe(story.id)

      expect(LLM.Mock, :chat, fn _request ->
        {:ok, %Response{text: Jason.encode!(@blueprint)}}
      end)

      test_pid = self()

      expect(Imagery.Mock, :generate, 2, fn _prompt ->
        send(test_pid, :portrait_attempted)
        {:error, :rate_limited}
      end)

      stub(Imagery.Mock, :generate, fn _prompt -> {:error, :rate_limited} end)
      stub(Imagery.Mock, :compose, fn _prompt, _references -> {:error, :rate_limited} end)

      assert {:ok, %Story{status: :live}} = Weaver.weave(story)

      assert_receive :portrait_attempted, 2_000
      assert_receive :portrait_attempted, 2_000
      refute_receive {:character_updated, %Character{avatar_type: "image/jpeg"}}, 100

      assert story.id
             |> Stories.list_characters()
             |> Enum.all?(&is_nil(&1.avatar_type))
    end
  end

  describe "parse_blueprint/1" do
    test "accepts a valid blueprint, even fenced" do
      text = "```json\n#{Jason.encode!(@blueprint)}\n```"

      assert {:ok, blueprint} = Weaver.parse_blueprint(text)
      assert blueprint.title == "The Door Below"
      assert [%{name: "Maren", energy: 2} | _] = blueprint.characters
    end

    test "rejects a blueprint missing an essential field" do
      assert :error =
               @blueprint |> Map.delete("opening") |> Jason.encode!() |> Weaver.parse_blueprint()
    end

    test "rejects a blueprint without locations" do
      assert :error =
               @blueprint
               |> Map.delete("locations")
               |> Jason.encode!()
               |> Weaver.parse_blueprint()

      assert :error =
               @blueprint
               |> Map.put("locations", [%{"name" => ""}])
               |> Jason.encode!()
               |> Weaver.parse_blueprint()
    end

    test "carries placements and agendas through to the blueprint" do
      assert {:ok, blueprint} = @blueprint |> Jason.encode!() |> Weaver.parse_blueprint()
      assert blueprint.opening_location == "The Shore"
      assert [%{name: "The Lamp Room"}, %{name: "The Shore"}] = blueprint.locations

      assert [
               %{
                 location: "The Shore",
                 agenda: "She has already been through the door.",
                 arc: "From gatekeeper to confessor.",
                 appearance: "Wind-burned, dark braid, a coat two sizes too big.",
                 entrance: "You are the woman walking up from the tideline."
               },
               %{
                 location: "The Lamp Room",
                 agenda: nil,
                 arc: nil,
                 appearance: "Weathered, salt-white beard, oilskin coat.",
                 entrance: nil
               }
             ] = blueprint.characters
    end

    test "carries the protagonist through, and tolerates a blueprint without one" do
      assert {:ok, blueprint} = @blueprint |> Jason.encode!() |> Weaver.parse_blueprint()
      assert blueprint.protagonist == "The keeper, who has tended this light for nine years."

      assert {:ok, %{protagonist: nil}} =
               @blueprint
               |> Map.delete("protagonist")
               |> Jason.encode!()
               |> Weaver.parse_blueprint()
    end

    test "avatar prompts paint from the appearance when there is one" do
      story = %Story{tone: "quietly ominous"}

      described = %AgenticStories.Stories.Character{
        name: "Maren",
        persona: "The keeper's sister.",
        appearance: "Wind-burned, dark braid."
      }

      assert Weaver.avatar_prompt(story, described) =~ "How they look: Wind-burned, dark braid."

      undescribed = %AgenticStories.Stories.Character{name: "Tosk", persona: "A diver."}
      refute Weaver.avatar_prompt(story, undescribed) =~ "How they look"

      told = %Story{
        tone: "quietly ominous",
        protagonist: "Jack, who keeps the light and lives alone."
      }

      assert Weaver.player_avatar_prompt(told) =~ "whom the story addresses as \"you\""
      assert Weaver.player_avatar_prompt(told) =~ "Jack, who keeps the light"

      sheet = Weaver.board_prompt(story, described)
      assert sheet =~ "exact visual identity"
      assert sheet =~ "CHARACTER SHEET LAYOUT"
      assert sheet =~ "Maren"
      assert sheet =~ "Wind-burned, dark braid."
      assert sheet =~ "Full-body FRONT"
      assert sheet =~ "Dress exactly as the description says"
      refute sheet =~ "Fully clothed"
      assert String.length(sheet) <= 1500

      player_sheet = Weaver.player_board_prompt(told)
      assert player_sheet =~ "whom the story addresses as \"you\""
      assert player_sheet =~ "Jack, who keeps the light"
      assert player_sheet =~ "CHARACTER SHEET LAYOUT"
      refute player_sheet =~ "Fully clothed"
      assert String.length(player_sheet) <= 1500
    end

    test "a long appearance still leaves the board prompt inside the edit cap" do
      looks =
        "Wind-burned, dark braid, a coat two sizes too big, salt in the seams, " <>
          "a scar at the left eyebrow, and the keeper's boots."

      story = %Story{tone: "quietly ominous, salt-stained, a little cruel"}

      character = %AgenticStories.Stories.Character{
        name: "Maren of the Outer Light",
        appearance: looks
      }

      assert String.length(Weaver.board_prompt(story, character)) <= 1500

      told = %Story{tone: story.tone, protagonist: looks}
      assert String.length(Weaver.player_board_prompt(told)) <= 1500
    end

    test "drops malformed characters and rejects an empty cast" do
      broken = Map.put(@blueprint, "characters", [%{"name" => "", "persona" => "x"}, %{}])
      assert :error = broken |> Jason.encode!() |> Weaver.parse_blueprint()

      mixed =
        Map.put(@blueprint, "characters", [
          %{
            "name" => "Maren",
            "persona" => "The keeper's sister.",
            "appearance" => "Wind-burned, dark braid, a coat two sizes too big."
          },
          %{"name" => "Tosk", "persona" => "A diver."},
          %{"persona" => "nameless"}
        ])

      assert {:ok, %{characters: [%{name: "Maren"}]}} =
               mixed |> Jason.encode!() |> Weaver.parse_blueprint()
    end
  end
end
