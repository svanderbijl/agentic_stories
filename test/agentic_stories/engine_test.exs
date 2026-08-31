defmodule AgenticStories.EngineTest do
  # async: false — seed_story weaves in a spawned task and ensure_running
  # flips global config; the shared sandbox keeps both simple.
  use AgenticStories.DataCase, async: false

  import AgenticStories.StoriesFixtures
  import Mox

  alias AgenticStories.Engine
  alias AgenticStories.Engine.CharacterAgent
  alias AgenticStories.LLM
  alias AgenticStories.LLM.Response
  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Character, Message, Story}

  setup :set_mox_global
  setup :verify_on_exit!

  describe "seed_story/1" do
    test "creates a weaving story and completes it in the background" do
      expect(LLM.Mock, :chat, fn _request ->
        {:ok,
         %Response{
           text:
             Jason.encode!(%{
               "title" => "The Door Below",
               "premise" => "p",
               "arc" => "a",
               "tone" => "t",
               "style" => "s",
               "opening" => "The tide pulls back.",
               "opening_location" => "The Shore",
               "locations" => [%{"name" => "The Shore", "description" => "Wet shingle."}],
               "characters" => [
                 %{
                   "name" => "Maren",
                   "persona" => "The keeper's sister.",
                   "appearance" => "Wind-burned, dark braid, a coat two sizes too big."
                 }
               ]
             })
         }}
      end)

      Stories.subscribe()

      assert {:ok, %Story{status: :weaving} = story} = Engine.seed_story("A door under the sea.")

      assert_receive {:story_updated, %Story{status: :live, title: "The Door Below"}}, 2_000
      assert [%{name: "Maren"}] = Stories.list_characters(story.id)
    end

    test "returns the changeset error for an invalid seed" do
      assert {:error, %Ecto.Changeset{}} = Engine.seed_story(" ")
    end

    @tag capture_log: true
    test "a crash in the weave frays the story instead of leaving it stuck" do
      expect(LLM.Mock, :chat, fn _request -> raise "ANTHROPIC_API_KEY is not set" end)

      Stories.subscribe()
      assert {:ok, %Story{}} = Engine.seed_story("A door under the sea.")

      assert_receive {:story_updated, %Story{status: :failed, failure_reason: reason}}, 2_000
      assert reason =~ "ANTHROPIC_API_KEY"
    end
  end

  describe "player_message/2" do
    test "records the message and energizes the cast" do
      story = story_fixture()
      character = character_fixture(story, %{energy: 0})
      pid = start_supervised!({CharacterAgent, character: character, story: story})
      send(pid, :tick)
      assert %{dormant?: true} = :sys.get_state(pid)

      Stories.subscribe(story.id)

      assert {:ok, %Message{kind: :player}} = Engine.player_message(story, "Hello?")

      assert_receive {:message_created, %Message{kind: :player, content: "Hello?"}}
      # player_energy is 6 in config; the dormant agent woke up with it
      assert %{energy: 6, dormant?: false} = :sys.get_state(pid)
    end

    test "asterisked input is a deed, not a line" do
      story = story_fixture()

      assert {:ok, %Message{kind: :act, content: "douse the lamp", character_id: nil}} =
               Engine.player_message(story, "*douse the lamp*")

      assert {:ok, %Message{kind: :act, content: "listen at the door"}} =
               Engine.player_message(story, "* listen at the door")

      assert {:ok, %Message{kind: :player, content: "Hello * there"}} =
               Engine.player_message(story, "Hello * there")
    end
  end

  describe "character_message/4" do
    test "passes the torch to the next cast member only, so chatter decays" do
      story = story_fixture()
      first = character_fixture(story, %{name: "Maren", energy: 1})
      speaker = character_fixture(story, %{name: "Old Tosk", energy: 4})
      third = character_fixture(story, %{name: "The Warden", energy: 1})

      pids =
        for {character, id} <- [{first, :first}, {speaker, :speaker}, {third, :third}],
            into: %{} do
          {id, start_supervised!({CharacterAgent, character: character, story: story}, id: id)}
        end

      assert {:ok, %Message{kind: :say}} =
               Engine.character_message(story, speaker, :say, "The sea keeps what it likes.")

      # chatter_energy (1) goes to the next character in cast order only
      assert %{energy: 2} = :sys.get_state(pids.third)
      assert %{energy: 1} = :sys.get_state(pids.first)
      assert %{energy: 4} = :sys.get_state(pids.speaker)
    end

    test "the torch wraps around from the last cast member to the first" do
      story = story_fixture()
      first = character_fixture(story, %{name: "Maren", energy: 1})
      speaker = character_fixture(story, %{name: "Old Tosk", energy: 4})

      first_pid = start_supervised!({CharacterAgent, character: first, story: story}, id: :first)

      assert {:ok, %Message{}} = Engine.character_message(story, speaker, :act, "nods slowly")
      assert %{energy: 2} = :sys.get_state(first_pid)
    end
  end

  describe "locality" do
    setup do
      story = story_fixture()
      lamp_room = location_fixture(story, %{name: "The Lamp Room"})
      shore = location_fixture(story, %{name: "The Shore"})
      {:ok, story} = Stories.move_player(story, lamp_room.id)

      # located stories check every player beat for narrated movement in a
      # background task; answer NOTHING and let tests await the check so it
      # never races test teardown
      test_pid = self()

      Mox.stub(LLM.Mock, :chat, fn request ->
        if request.system =~ "decide whether the player", do: send(test_pid, :intent_checked)
        {:ok, %Response{text: "NOTHING"}}
      end)

      %{story: story, lamp_room: lamp_room, shore: shore}
    end

    test "a player message fully charges the room and trickles elsewhere", ctx do
      near =
        character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.lamp_room.id})

      far =
        character_fixture(ctx.story, %{name: "Old Tosk", energy: 0, location_id: ctx.shore.id})

      near_pid = start_supervised!({CharacterAgent, character: near, story: ctx.story}, id: :near)
      far_pid = start_supervised!({CharacterAgent, character: far, story: ctx.story}, id: :far)

      assert {:ok, %Message{location_id: location_id}} =
               Engine.player_message(ctx.story, "Hello?")

      assert location_id == ctx.lamp_room.id
      # player_energy 6 in the room, ambient_energy 2 elsewhere
      assert %{energy: 6} = :sys.get_state(near_pid)
      assert %{energy: 2} = :sys.get_state(far_pid)
      assert_receive :intent_checked, 1_000
    end

    test "the torch only passes within the same place", ctx do
      speaker =
        character_fixture(ctx.story, %{name: "Maren", energy: 4, location_id: ctx.lamp_room.id})

      near =
        character_fixture(ctx.story, %{name: "Brahm", energy: 1, location_id: ctx.lamp_room.id})

      far =
        character_fixture(ctx.story, %{name: "Old Tosk", energy: 1, location_id: ctx.shore.id})

      near_pid = start_supervised!({CharacterAgent, character: near, story: ctx.story}, id: :near)
      far_pid = start_supervised!({CharacterAgent, character: far, story: ctx.story}, id: :far)

      assert {:ok, _message} = Engine.character_message(ctx.story, speaker, :say, "Look at this.")

      assert %{energy: 2} = :sys.get_state(near_pid)
      assert %{energy: 1} = :sys.get_state(far_pid)
    end

    test "a beat that narrates movement executes it", ctx do
      Mox.stub(LLM.Mock, :chat, fn request ->
        if request.system =~ "decide whether the player" do
          {:ok, %Response{text: "The Shore"}}
        else
          {:ok, %Response{text: "NOTHING"}}
        end
      end)

      Stories.subscribe(ctx.story.id)

      assert {:ok, %Message{kind: :player}} =
               Engine.player_message(ctx.story, "I walk down to the shore.")

      assert_receive {:story_updated, %Story{player_location_id: shore_id}}, 2_000
      assert shore_id == ctx.shore.id

      assert_receive {:message_created,
                      %Message{kind: :narration, content: "You make your way to The Shore."}},
                     2_000
    end

    test "player_move relocates, narrates at both ends, and charges the destination", ctx do
      dweller =
        character_fixture(ctx.story, %{name: "Old Tosk", energy: 0, location_id: ctx.shore.id})

      pid = start_supervised!({CharacterAgent, character: dweller, story: ctx.story})
      Stories.subscribe(ctx.story.id)

      assert {:ok, %Story{player_location_id: shore_id}} =
               Engine.player_move(ctx.story, ctx.shore.id)

      assert shore_id == ctx.shore.id
      assert_receive {:message_created, %Message{kind: :narration, witnessed_by_player: true}}
      assert %{energy: 6} = :sys.get_state(pid)
    end

    test "player_seek finds a wandered character, revealing where they were", ctx do
      away = character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.shore.id})
      Stories.subscribe(ctx.story.id)

      assert {:ok, %Story{player_location_id: shore_id}} = Engine.player_seek(ctx.story, away.id)
      assert shore_id == ctx.shore.id

      assert_receive {:message_created,
                      %Message{
                        kind: :narration,
                        content: "You go looking for Maren, and find them at The Shore.",
                        witnessed_by_player: true
                      }}
    end

    test "player_seek is a quiet no-op when the character is with you, or nowhere", ctx do
      here = character_fixture(ctx.story, %{name: "Maren", location_id: ctx.lamp_room.id})

      assert {:ok, %Story{player_location_id: origin}} = Engine.player_seek(ctx.story, here.id)
      assert origin == ctx.story.player_location_id

      lost = character_fixture(ctx.story, %{name: "Old Tosk", location_id: nil})
      assert {:ok, %Story{}} = Engine.player_seek(ctx.story, lost.id)
    end

    test "character_move records one beat witnessed at both ends and relocates", ctx do
      character =
        character_fixture(ctx.story, %{name: "Maren", energy: 4, location_id: ctx.shore.id})

      location = ctx.lamp_room

      assert {:ok, %Message{} = message, %{location_id: new_location}} =
               Engine.character_move(ctx.story, character, location, "climbs the stairs")

      assert new_location == location.id
      # the player (in the lamp room) sees the arrival
      assert message.witnessed_by_player == true
    end

    test "speaking to an absent character pulls them back into the scene", ctx do
      away = character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.shore.id})
      pid = start_supervised!({CharacterAgent, character: away, story: ctx.story})
      Stories.subscribe(ctx.story.id)

      assert {:ok, %Message{}} =
               Engine.player_message(ctx.story, "Maren, where did you go? Come back.")

      # she is pulled to the player before the words land…
      assert Stories.get_character!(away.id).location_id == ctx.lamp_room.id
      assert %{character: %{location_id: agent_location}} = :sys.get_state(pid)
      assert agent_location == ctx.lamp_room.id

      # …arriving visibly, so the record stays honest
      assert_receive {:message_created, %Message{kind: :act, witnessed_by_player: true}}

      # …so she hears the summons and gets the full co-located charge
      memory = Stories.character_memory(Stories.get_character!(away.id), 40)
      assert Enum.any?(memory, &(&1.content =~ "where did you go"))
      assert %{energy: 6} = :sys.get_state(pid)
    end

    test "walking off mid-sentence takes the person you invited with you", ctx do
      # the Vivian bug: the player says "let's go to the shore", the narrated
      # move walks them out, and the character they just addressed is left
      # behind in the room the player abandoned — forever "elsewhere".
      invited =
        character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.lamp_room.id})

      start_supervised!({CharacterAgent, character: invited, story: ctx.story})
      Stories.subscribe(ctx.story.id)
      test_pid = self()

      Mox.stub(LLM.Mock, :chat, fn request ->
        if request.system =~ "decide whether the player" do
          send(test_pid, :intent_checked)
          {:ok, %Response{text: "The Shore"}}
        else
          {:ok, %Response{text: "NOTHING"}}
        end
      end)

      assert {:ok, %Message{}} =
               Engine.player_message(ctx.story, "Maren, let's walk down to the shore.")

      assert_receive :intent_checked, 1_000

      # the player went…
      assert_receive {:message_created, %Message{content: "You make your way to The Shore."}},
                     1_000

      assert Stories.get_story!(ctx.story.id).player_location_id == ctx.shore.id

      # …and so did she, visibly (a live agent is told through the same
      # CharacterAgent.relocated path the summon above already covers)
      assert_receive {:message_created, %Message{content: "follows you to The Shore"}}, 1_000
      assert Stories.get_character!(invited.id).location_id == ctx.shore.id
    end

    test "walking off alone leaves the cast where they stand", ctx do
      stays =
        character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.lamp_room.id})

      Stories.subscribe(ctx.story.id)
      test_pid = self()

      Mox.stub(LLM.Mock, :chat, fn request ->
        if request.system =~ "decide whether the player" do
          send(test_pid, :intent_checked)
          {:ok, %Response{text: "The Shore"}}
        else
          {:ok, %Response{text: "NOTHING"}}
        end
      end)

      assert {:ok, %Message{}} = Engine.player_message(ctx.story, "I head down to the shore.")
      assert_receive :intent_checked, 1_000

      assert_receive {:message_created, %Message{content: "You make your way to The Shore."}},
                     1_000

      assert Stories.get_story!(ctx.story.id).player_location_id == ctx.shore.id
      assert Stories.get_character!(stays.id).location_id == ctx.lamp_room.id
    end

    test "a mention that is not the character's name summons nobody", ctx do
      away = character_fixture(ctx.story, %{name: "Art", energy: 0, location_id: ctx.shore.id})

      assert {:ok, %Message{}} =
               Engine.player_message(ctx.story, "Quite a start to the evening.")

      assert Stories.get_character!(away.id).location_id == ctx.shore.id
    end

    test "the Director may move a character, and a running agent follows", ctx do
      wanderer =
        character_fixture(ctx.story, %{name: "Maren", energy: 0, location_id: ctx.shore.id})

      pid = start_supervised!({CharacterAgent, character: wanderer, story: ctx.story})
      Stories.subscribe(ctx.story.id)

      direction = {:move_character, "Maren", "The Lamp Room", "comes back up the stairs"}

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 direction,
                 Stories.list_characters(ctx.story.id),
                 Stories.list_locations(ctx.story.id)
               )

      # the arrival is a beat the player (in the lamp room) sees
      assert_receive {:message_created,
                      %Message{
                        kind: :act,
                        content: "comes back up the stairs",
                        witnessed_by_player: true
                      }}

      assert Stories.get_character!(wanderer.id).location_id == ctx.lamp_room.id
      # the live agent must not keep acting from the old room
      assert %{character: %{location_id: agent_location}} = :sys.get_state(pid)
      assert agent_location == ctx.lamp_room.id
    end

    test "a Director move to somewhere new opens the place; an unknown name is a no-op", ctx do
      wanderer = character_fixture(ctx.story, %{name: "Maren", location_id: ctx.shore.id})
      Stories.subscribe(ctx.story.id)

      characters = Stories.list_characters(ctx.story.id)
      locations = Stories.list_locations(ctx.story.id)

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:move_character, "Nobody Here", "The Shore", nil},
                 characters,
                 locations
               )

      refute_receive {:message_created, _message}, 50

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:move_character, "Maren", "The Sea Caves", nil},
                 characters,
                 locations
               )

      assert_receive {:location_created,
                      %AgenticStories.Stories.Location{name: "The Sea Caves"} = caves}

      assert Stories.get_character!(wanderer.id).location_id == caves.id
    end

    test "the Director may change how a character looks, and a running agent follows", ctx do
      wanderer =
        character_fixture(ctx.story, %{
          name: "Maren",
          energy: 0,
          location_id: ctx.lamp_room.id,
          appearance: "Wind-burned, dark braid, a coat two sizes too big."
        })

      pid = start_supervised!({CharacterAgent, character: wanderer, story: ctx.story})
      Stories.subscribe(ctx.story.id)

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:looks, "Maren", "dark braid, a red silk dress, the coat gone",
                  "steps out of the coat and into the dress"},
                 Stories.list_characters(ctx.story.id),
                 Stories.list_locations(ctx.story.id)
               )

      assert_receive {:message_created,
                      %Message{
                        kind: :act,
                        content: "steps out of the coat and into the dress",
                        witnessed_by_player: true
                      }}

      assert Stories.get_character!(wanderer.id).appearance ==
               "dark braid, a red silk dress, the coat gone"

      assert %{character: %{appearance: appearance}} = :sys.get_state(pid)
      assert appearance == "dark braid, a red silk dress, the coat gone"
    end

    test "a Director looks change with no beat still updates the character; an unknown name is a no-op",
         ctx do
      wanderer =
        character_fixture(ctx.story, %{
          name: "Maren",
          location_id: ctx.lamp_room.id,
          appearance: "a coat two sizes too big."
        })

      Stories.subscribe(ctx.story.id)
      characters = Stories.list_characters(ctx.story.id)
      locations = Stories.list_locations(ctx.story.id)

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:looks, "Nobody Here", "a red dress", nil},
                 characters,
                 locations
               )

      refute_receive {:message_created, _message}, 50
      assert Stories.get_character!(wanderer.id).appearance == "a coat two sizes too big."

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:looks, "Maren", "a red silk dress", nil},
                 characters,
                 locations
               )

      refute_receive {:message_created, %Message{kind: :act}}, 50
      assert Stories.get_character!(wanderer.id).appearance == "a red silk dress"
    end
  end

  describe "scene plates" do
    setup do
      config = Application.fetch_env!(:agentic_stories, AgenticStories.Imagery)
      on_exit(fn -> Application.put_env(:agentic_stories, AgenticStories.Imagery, config) end)

      Application.put_env(
        :agentic_stories,
        AgenticStories.Imagery,
        Keyword.put(config, :enabled, true)
      )

      story = story_fixture()
      lamp_room = location_fixture(story, %{name: "The Lamp Room"})
      shore = location_fixture(story, %{name: "The Shore", description: "Wet shingle."})
      {:ok, story} = Stories.move_player(story, lamp_room.id)
      Stories.subscribe(story.id)
      %{story: story, lamp_room: lamp_room, shore: shore}
    end

    test "present characters ride along as sheet references", ctx do
      character =
        character_fixture(ctx.story, %{
          name: "Old Tosk",
          location_id: ctx.shore.id,
          appearance: "Weathered, salt-white beard, oilskin coat."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")
      {:ok, _} = Stories.put_character_board(character, <<9, 9, 9>>, "image/jpeg")

      # Venice multi-edit treats image 1 as the canvas. That slot has to be
      # a person (the sheet): a generated scene there is how two plates grow
      # two casts. Clothing still comes from the scene, not from the board.
      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert prompt =~ "The Shore — Wet shingle."
        assert prompt =~ "source image 1: Old Tosk — Weathered, salt-white beard, oilskin coat."
        assert prompt =~ "character reference sheet"
        assert prompt =~ "FRONT VIEW"
        assert prompt =~ "same faces"
        assert prompt =~ "Clothing"
        assert prompt =~ "Nobody looks at the camera"
        assert prompt =~ "mid-action"
        assert prompt =~ "The tide turns."
        assert prompt =~ "- the player"
        assert [%{binary: <<9, 9, 9>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<1, 2, 3>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.commission_plate(ctx.story, ctx.shore, "The Shore", "The tide turns.")

      assert_receive {:character_updated, _}, 1_000

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Shore"}},
                     1_000
    end

    test "a portrait is the fallback when no sheet has been painted yet", ctx do
      character =
        character_fixture(ctx.story, %{
          name: "Old Tosk",
          location_id: ctx.shore.id,
          appearance: "Weathered, salt-white beard, oilskin coat."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")

      expect(AgenticStories.Imagery.Mock, :compose, fn _prompt, references ->
        assert [%{binary: <<255, 216, 255>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<1, 2, 3>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.commission_plate(ctx.story, ctx.shore, "The Shore", "The tide turns.")

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Shore"}},
                     1_000
    end

    test "the player's sheet leads the compose so their face stays put", ctx do
      {:ok, story} =
        ctx.story
        |> Ecto.Changeset.change(
          protagonist: "Jack, salt in his hair, the keeper's coat still on."
        )
        |> AgenticStories.Repo.update()

      {:ok, story} = Stories.put_player_avatar(story, <<1, 2, 3>>, "image/jpeg")
      {:ok, story} = Stories.put_player_board(story, <<4, 5, 6>>, "image/jpeg")

      character =
        character_fixture(story, %{
          name: "Old Tosk",
          location_id: ctx.shore.id,
          appearance: "Weathered, salt-white beard, oilskin coat."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")
      {:ok, _} = Stories.put_character_board(character, <<7, 8, 9>>, "image/jpeg")

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert [
                 %{binary: <<4, 5, 6>>, content_type: "image/jpeg"},
                 %{binary: <<7, 8, 9>>, content_type: "image/jpeg"}
               ] = references

        assert prompt =~ "source image 1: the player — Jack, salt in his hair"
        assert prompt =~ "source image 2: Old Tosk — Weathered, salt-white beard, oilskin coat."
        refute prompt =~ "- the player\n"
        {:ok, %{binary: <<9>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.commission_plate(story, ctx.shore, "The Shore", "The tide turns.")

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Shore"}},
                     1_000
    end

    test "a story with no player portrait yet paints one before the plate", ctx do
      {:ok, story} =
        ctx.story
        |> Ecto.Changeset.change(protagonist: "Jack, who keeps the light and lives alone.")
        |> AgenticStories.Repo.update()

      expect(AgenticStories.Imagery.Mock, :generate, fn prompt ->
        assert prompt =~ "whom the story addresses as \"you\""
        assert prompt =~ "Jack, who keeps the light"
        {:ok, %{binary: <<1, 2, 3>>, content_type: "image/jpeg"}}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert String.contains?(prompt, "CHARACTER SHEET LAYOUT")
        assert [%{binary: <<1, 2, 3>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<8>>, content_type: "image/jpeg"}}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert [%{binary: <<8>>, content_type: "image/jpeg"}] = references
        assert prompt =~ "source image 1: the player — Jack, who keeps the light"
        {:ok, %{binary: <<9>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.commission_plate(story, ctx.shore, "The Shore", "The tide turns.")

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Shore"}},
                     1_000

      assert {<<1, 2, 3>>, "image/jpeg"} = Stories.get_player_avatar(story.id)
      assert {<<8>>, "image/jpeg"} = Stories.get_player_board(story.id)
    end

    test "a declined composition still paints the scene from words", ctx do
      character = character_fixture(ctx.story, %{location_id: ctx.shore.id})
      {:ok, _} = Stories.put_character_avatar(character, <<255>>, "image/jpeg")

      expect(AgenticStories.Imagery.Mock, :compose, fn _prompt, _references ->
        {:error, {:http_error, 422, %{"error" => "Your prompt violates the content policy"}}}
      end)

      expect(AgenticStories.Imagery.Mock, :generate, fn prompt ->
        assert prompt =~ "- the player"
        {:ok, %{binary: <<9>>, content_type: "image/jpeg"}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Engine.commission_plate(ctx.story, ctx.shore, "The Shore", "The tide turns.")

          assert_receive {:message_created, %Message{kind: :illustration}}, 1_000
        end)

      assert log =~ "no composition for"
      assert log =~ "Your prompt violates the content policy"
      assert log =~ "prompt:"
      assert log =~ "The Shore — Wet shingle."
      assert log =~ "The tide turns."
    end

    test "a long tableau is clipped so the compose prompt fits the edit model", ctx do
      character =
        character_fixture(ctx.story, %{
          name: "Old Tosk",
          location_id: ctx.shore.id,
          appearance: "Weathered, salt-white beard, oilskin coat."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255>>, "image/jpeg")

      scene =
        "An establishing view of the wet shingle under a low sky. " <>
          String.duplicate(
            "Old Tosk stands at the waterline, oilskin snapping in the wind. ",
            30
          )

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, _references ->
        assert String.length(prompt) <= 1500
        assert prompt =~ "source image 1: Old Tosk"
        assert prompt =~ "FRONT VIEW"
        assert prompt =~ "An establishing view of the wet shingle"
        {:ok, %{binary: <<9>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.commission_plate(ctx.story, ctx.shore, "The Shore", scene)

      assert_receive {:message_created, %Message{kind: :illustration}}, 1_000
    end

    test "each place earns exactly one establishing plate, on first arrival", ctx do
      stub(AgenticStories.Imagery.Mock, :generate, fn prompt ->
        assert prompt =~ "establishing view"
        {:ok, %{binary: <<7>>, content_type: "image/jpeg"}}
      end)

      {:ok, story} = Engine.player_move(ctx.story, ctx.shore.id)

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Shore"}},
                     1_000

      {:ok, story} = Engine.player_move(story, ctx.lamp_room.id)

      assert_receive {:message_created, %Message{kind: :illustration, content: "The Lamp Room"}},
                     1_000

      {:ok, _story} = Engine.player_move(story, ctx.shore.id)
      refute_receive {:message_created, %Message{kind: :illustration}}, 100
    end

    test "the player can ask for a picture; the Narrator reads the scene back first", ctx do
      character_fixture(ctx.story, %{name: "Maren", location_id: ctx.lamp_room.id})

      # written straight to the log: player_message/2 would also spawn the
      # implied-move read, and that would race this test for the mock
      {:ok, _} =
        Stories.create_message(ctx.story, %{
          kind: :player,
          content: "I take off my coat.",
          location_id: ctx.lamp_room.id
        })

      expect(AgenticStories.LLM.Mock, :chat, fn request ->
        # the read-back gets the record, not just the cast list, and it is
        # asked for prose — not JSON a small model will mangle
        assert request.system =~ "WEARING"
        refute request.system =~ "JSON"
        assert hd(request.messages).content =~ "I take off my coat."
        assert hd(request.messages).content =~ "Maren"

        {:ok,
         %AgenticStories.LLM.Response{
           text: "CAPTION: Unbuttoned\nMaren by the window, coat over the chair."
         }}
      end)

      expect(AgenticStories.Imagery.Mock, :generate, fn prompt ->
        assert prompt =~ "coat over the chair"
        {:ok, %{binary: <<3>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.request_plate(ctx.story)

      assert_receive {:message_created, %Message{kind: :illustration, content: "Unbuttoned"}},
                     1_000
    end

    test "a changed outfit in the record is what the plate paints, not the portrait's clothes",
         ctx do
      character =
        character_fixture(ctx.story, %{
          name: "Maren",
          location_id: ctx.lamp_room.id,
          appearance: "Wind-burned, dark braid, a coat two sizes too big."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")

      {:ok, _} =
        Stories.create_message(ctx.story, %{
          kind: :act,
          content: "steps out of the coat and into a red silk dress",
          character_id: character.id,
          location_id: ctx.lamp_room.id
        })

      expect(AgenticStories.LLM.Mock, :chat, fn request ->
        assert request.system =~ "WEARING"
        assert hd(request.messages).content =~ "red silk dress"

        assert hd(request.messages).content =~
                 "Maren: Wind-burned, dark braid, a coat two sizes too big."

        {:ok,
         %AgenticStories.LLM.Response{
           text: """
           CAPTION: Changed
           LOOKS:
           - Maren: dark braid, a red silk dress, the coat gone
           Maren in a red silk dress, the coat on the floor.
           """
         }}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert String.contains?(prompt, "CHARACTER SHEET LAYOUT")
        assert prompt =~ "dark braid, a red silk dress, the coat gone"
        assert [%{binary: <<255, 216, 255>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<8>>, content_type: "image/jpeg"}}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert prompt =~ "Head and shoulders"
        assert [%{binary: <<8>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<7>>, content_type: "image/jpeg"}}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert [%{binary: <<8>>, content_type: "image/jpeg"}] = references
        assert prompt =~ "source image 1: Maren — dark braid, a red silk dress, the coat gone"
        assert prompt =~ "red silk dress"
        {:ok, %{binary: <<1, 2, 3>>, content_type: "image/jpeg"}}
      end)

      assert :ok = Engine.request_plate(ctx.story)

      assert_receive {:message_created, %Message{kind: :illustration, content: "Changed"}},
                     1_000

      assert Stories.get_character!(character.id).appearance ==
               "dark braid, a red silk dress, the coat gone"
    end

    test "a failed read-back costs the player a picture, not the story", ctx do
      test_pid = self()

      expect(AgenticStories.LLM.Mock, :chat, fn _request ->
        send(test_pid, :read_back_attempted)
        {:error, :rate_limited}
      end)

      assert :ok = Engine.request_plate(ctx.story)

      assert_receive :read_back_attempted, 1_000
      refute_receive {:message_created, %Message{kind: :illustration}}, 100
    end

    test "a finished story cannot be pictured", ctx do
      {:ok, story} = Stories.finish_story(ctx.story)
      assert :ok = Engine.request_plate(story)
      refute_receive {:message_created, %Message{kind: :illustration}}, 100
    end

    test "an ending earns a closing plate", ctx do
      stub(AgenticStories.Imagery.Mock, :generate, fn prompt ->
        assert prompt =~ "the lamp goes out"
        {:ok, %{binary: <<7>>, content_type: "image/jpeg"}}
      end)

      {:ok, _story} = Engine.finish_story(ctx.story, "And so the lamp goes out.")

      assert_receive {:message_created, %Message{kind: :illustration, content: "The end"}}, 1_000
    end

    test "the Director may illustrate a turn, but not two in a row", ctx do
      stub(AgenticStories.Imagery.Mock, :generate, fn _prompt ->
        {:ok, %{binary: <<7>>, content_type: "image/jpeg"}}
      end)

      locations = Stories.list_locations(ctx.story.id)
      direction = {:illustrate, "She turns from the rail.", "The turn"}

      Engine.apply_direction(ctx.story, direction, [], locations)
      assert_receive {:message_created, %Message{kind: :illustration, content: "The turn"}}, 1_000

      # the cooldown is beats of clear air, and none have passed
      Engine.apply_direction(ctx.story, direction, [], locations)
      refute_receive {:message_created, %Message{kind: :illustration}}, 100
    end

    test "a Director looks change rebuilds the sheet from the old likeness", ctx do
      character =
        character_fixture(ctx.story, %{
          name: "Maren",
          location_id: ctx.lamp_room.id,
          appearance: "Wind-burned, dark braid, a coat two sizes too big."
        })

      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")
      {:ok, _} = Stories.put_character_board(character, <<1, 2, 3>>, "image/jpeg")
      assert_receive {:character_updated, %Character{avatar_type: "image/jpeg"}}
      assert_receive {:character_updated, %Character{board_type: "image/jpeg"}}

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert String.contains?(prompt, "CHARACTER SHEET LAYOUT")
        assert prompt =~ "dark braid, a red silk dress"
        refute prompt =~ "coat two sizes too big"
        assert [%{binary: <<1, 2, 3>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<8>>, content_type: "image/jpeg"}}
      end)

      expect(AgenticStories.Imagery.Mock, :compose, fn prompt, references ->
        assert prompt =~ "Head and shoulders"
        assert [%{binary: <<8>>, content_type: "image/jpeg"}] = references
        {:ok, %{binary: <<7>>, content_type: "image/jpeg"}}
      end)

      assert :ok =
               Engine.apply_direction(
                 ctx.story,
                 {:looks, "Maren", "dark braid, a red silk dress", nil},
                 Stories.list_characters(ctx.story.id),
                 Stories.list_locations(ctx.story.id)
               )

      assert_receive {:character_updated, %Character{appearance: "dark braid, a red silk dress"}},
                     1_000

      assert_receive {:character_updated, %Character{board_type: "image/jpeg"}}, 1_000
      assert_receive {:character_updated, %Character{avatar_type: "image/jpeg"}}, 1_000
      assert {<<8>>, "image/jpeg"} = Stories.get_board(character.id)
      assert {<<7>>, "image/jpeg"} = Stories.get_avatar(character.id)
    end
  end

  describe "end_story/1 and delete_story/1" do
    test "ending a story closes the book and retires the cast" do
      story = story_fixture()
      character = character_fixture(story)

      pid = start_supervised!({CharacterAgent, character: character, story: story})
      Process.unlink(pid)
      ref = Process.monitor(pid)

      Stories.subscribe(story.id)

      assert {:ok, %Story{status: :finished}} = Engine.end_story(story)

      assert_receive {:message_created,
                      %Message{kind: :narration, content: "Here you close" <> _}}

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert Stories.get_story!(story.id).status == :finished

      # ending an already-finished story is a quiet no-op
      assert {:ok, %Story{}} = Engine.end_story(Stories.get_story!(story.id))
    end

    test "deleting a story retires agents, removes everything, and broadcasts" do
      story = story_fixture()
      character = character_fixture(story)
      message_fixture(story)

      pid = start_supervised!({CharacterAgent, character: character, story: story})
      Process.unlink(pid)
      ref = Process.monitor(pid)

      Stories.subscribe(story.id)

      assert {:ok, %Story{}} = Engine.delete_story(story)

      assert_receive {:story_deleted, %Story{}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_raise Ecto.NoResultsError, fn -> Stories.get_story!(story.id) end
      assert Stories.list_messages(story.id) == []
    end
  end

  describe "ensure_running/1" do
    test "is a no-op while agents are disabled (the test default)" do
      story = story_fixture()
      character = character_fixture(story)

      assert :ok = Engine.ensure_running(story)
      assert CharacterAgent.whereis(character.id) == nil
    end

    test "starts an agent per character when enabled, idempotently" do
      config = Application.fetch_env!(:agentic_stories, AgenticStories.Engine)
      on_exit(fn -> Application.put_env(:agentic_stories, AgenticStories.Engine, config) end)

      Application.put_env(
        :agentic_stories,
        AgenticStories.Engine,
        Keyword.put(config, :start_agents, true)
      )

      story = story_fixture()
      character = character_fixture(story)

      assert :ok = Engine.ensure_running(story)
      pid = CharacterAgent.whereis(character.id)
      assert is_pid(pid)

      # idempotent: a second call reuses the running agent
      assert :ok = Engine.ensure_running(story)
      assert CharacterAgent.whereis(character.id) == pid

      # the Director rises with the cast
      director = AgenticStories.Engine.DirectorAgent.whereis(story.id)
      assert is_pid(director)

      on_exit(fn ->
        for agent <- [pid, director] do
          DynamicSupervisor.terminate_child(AgenticStories.Engine.CharacterSupervisor, agent)
        end
      end)
    end

    test "ignores stories that are not live" do
      story = weaving_story_fixture()
      assert :ok = Engine.ensure_running(story)
    end
  end
end
