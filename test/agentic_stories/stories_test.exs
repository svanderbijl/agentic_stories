defmodule AgenticStories.StoriesTest do
  use AgenticStories.DataCase, async: true

  import AgenticStories.StoriesFixtures

  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Character, Message, Story}

  describe "create_story/1" do
    test "creates a weaving story from a seed and broadcasts it" do
      Stories.subscribe()

      assert {:ok, %Story{} = story} = Stories.create_story(%{seed: "  A city that dreams.  "})
      assert story.status == :weaving
      assert story.seed == "A city that dreams."

      # pin the id: other async tests broadcast on the global topic too
      story_id = story.id
      assert_receive {:story_updated, %Story{id: ^story_id}}
    end

    test "rejects a blank seed" do
      assert {:error, changeset} = Stories.create_story(%{seed: "   "})
      assert %{seed: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "complete_weaving/2" do
    test "makes the story live with cast and opening in one transaction" do
      story = weaving_story_fixture()
      Stories.subscribe(story.id)

      blueprint = %{
        title: "The Door Below",
        premise: "A keeper finds a door on the seabed.",
        arc: "Down, through, and changed.",
        tone: "quietly ominous",
        style: "Spare prose.",
        opening: "The tide pulls back further than it should.",
        characters: [
          %{name: "Maren", persona: "The keeper's sister.", voice: "Clipped.", energy: 2},
          %{name: "Old Tosk", persona: "A retired diver.", voice: "Slow.", energy: 2}
        ]
      }

      assert {:ok, %Story{status: :live, title: "The Door Below"}} =
               Stories.complete_weaving(story, blueprint)

      assert [%Character{name: "Maren", energy: 2}, %Character{name: "Old Tosk"}] =
               Stories.list_characters(story.id)

      assert [%Message{kind: :narration, content: "The tide pulls back" <> _}] =
               Stories.list_messages(story.id)

      assert_receive {:story_updated, %Story{status: :live}}
    end

    test "places the world: locations, cast, player, and opening witnesses" do
      story = weaving_story_fixture()

      blueprint = %{
        title: "The Door Below",
        premise: "p",
        arc: "a",
        tone: "t",
        style: "s",
        opening: "The tide pulls back.",
        opening_location: "The Shore",
        locations: [
          %{name: "The Lamp Room", description: "Hot brass."},
          %{name: "The Shore", description: "Wet shingle."}
        ],
        characters: [
          %{name: "Maren", persona: "The keeper's sister.", location: "The Shore", energy: 2},
          %{name: "Old Tosk", persona: "A retired diver.", location: "The Lamp Room", energy: 2}
        ]
      }

      assert {:ok, %Story{} = story} = Stories.complete_weaving(story, blueprint)

      assert [lamp_room, shore] = Stories.list_locations(story.id)
      assert lamp_room.name == "The Lamp Room"
      assert story.player_location_id == shore.id

      assert [maren, tosk] = Stories.list_characters(story.id)
      assert maren.location_id == shore.id
      assert tosk.location_id == lamp_room.id

      # the opening is witnessed by the player and whoever shares the scene
      assert [%Message{kind: :narration, witnessed_by_player: true}] =
               Stories.player_messages(story.id)

      assert [%Message{kind: :narration}] = Stories.character_memory(maren, 10)
      assert [] = Stories.character_memory(tosk, 10)
    end

    test "fails atomically when the blueprint is incomplete" do
      story = weaving_story_fixture()
      blueprint = %{premise: "p", arc: "a", tone: "t", style: "s", opening: "o", characters: []}

      assert {:error, %Ecto.Changeset{}} = Stories.complete_weaving(story, blueprint)
      assert Stories.get_story!(story.id).status == :weaving
      assert Stories.list_messages(story.id) == []
    end
  end

  describe "fray_orphaned_weaves/0" do
    test "frays weaving stories and leaves the rest alone" do
      orphan = weaving_story_fixture()
      live = story_fixture()

      assert Stories.fray_orphaned_weaves() >= 1

      assert %Story{status: :failed, failure_reason: "the loom went cold mid-weave"} =
               Stories.get_story!(orphan.id)

      assert Stories.get_story!(live.id).status == :live
    end
  end

  describe "fail_weaving/2" do
    test "marks the story failed with a reason and broadcasts" do
      story = weaving_story_fixture()
      Stories.subscribe(story.id)

      assert {:ok, %Story{status: :failed, failure_reason: "the weave came apart"}} =
               Stories.fail_weaving(story, "the weave came apart")

      assert_receive {:story_updated, %Story{status: :failed}}
    end
  end

  describe "messages" do
    test "create_message/2 stores, preloads the character, and broadcasts" do
      story = story_fixture()
      character = character_fixture(story)
      Stories.subscribe(story.id)

      assert {:ok, %Message{} = message} =
               Stories.create_message(story, %{
                 kind: :say,
                 content: "The sea keeps what it likes.",
                 character_id: character.id
               })

      assert message.character.name == "Maren"
      assert_receive {:message_created, %Message{kind: :say}}
    end

    test "create_message/2 rejects blank content" do
      story = story_fixture()
      assert {:error, changeset} = Stories.create_message(story, %{kind: :player, content: " "})
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "character_memory/2 trims in chunks, and only what memory already holds" do
      story = story_fixture()
      character = character_fixture(story)

      for n <- 1..4 do
        message_fixture(story, %{kind: :player, content: "beat #{n}"})
      end

      # past 2 * window, but nothing is consolidated yet: no hole, no trim
      assert ["beat 1", "beat 2", "beat 3", "beat 4"] = memory_contents(character, 2)

      # once the chunk lives in long-term memory, the trim happens at once
      {:ok, character} = Stories.append_character_memory(character, "I remember.", 2)
      assert ["beat 3", "beat 4"] = memory_contents(character, 2)

      message_fixture(story, %{kind: :player, content: "beat 5"})

      # the next beat appends without moving the head: a stable prefix
      assert ["beat 3", "beat 4", "beat 5"] = memory_contents(character, 2)
    end
  end

  defp memory_contents(character, window) do
    character |> Stories.character_memory(window) |> Enum.map(& &1.content)
  end

  describe "witnessing" do
    setup do
      story = story_fixture()
      lamp_room = location_fixture(story, %{name: "The Lamp Room"})
      shore = location_fixture(story, %{name: "The Shore"})
      {:ok, story} = Stories.move_player(story, lamp_room.id)

      maren = character_fixture(story, %{name: "Maren", location_id: lamp_room.id})
      tosk = character_fixture(story, %{name: "Old Tosk", location_id: shore.id})

      %{story: story, lamp_room: lamp_room, shore: shore, maren: maren, tosk: tosk}
    end

    test "a beat is witnessed only by those present", ctx do
      {:ok, message} =
        Stories.create_message(ctx.story, %{
          kind: :say,
          content: "The light is wrong tonight.",
          character_id: ctx.maren.id,
          location_id: ctx.lamp_room.id
        })

      assert message.witnessed_by_player == true
      assert ["The light is wrong tonight."] = memory_contents(ctx.maren, 10)
      assert [] = memory_contents(ctx.tosk, 10)
    end

    test "a beat away from the player stays out of the reading pane", ctx do
      {:ok, message} =
        Stories.create_message(ctx.story, %{
          kind: :act,
          content: "drags something heavy up the shingle",
          character_id: ctx.tosk.id,
          location_id: ctx.shore.id
        })

      assert message.witnessed_by_player == false
      assert Stories.player_messages(ctx.story.id) == []
      assert ["drags something heavy up the shingle"] = memory_contents(ctx.tosk, 10)
      assert [] = memory_contents(ctx.maren, 10)
    end

    test "a move beat is witnessed at both ends", ctx do
      {:ok, message} =
        Stories.create_message(ctx.story, %{
          kind: :act,
          content: "trudges up from the shore",
          character_id: ctx.tosk.id,
          location_id: ctx.lamp_room.id,
          witness_location_ids: [ctx.shore.id, ctx.lamp_room.id]
        })

      assert message.witnessed_by_player == true
      assert ["trudges up from the shore"] = memory_contents(ctx.maren, 10)
      assert ["trudges up from the shore"] = memory_contents(ctx.tosk, 10)
    end

    test "player witnessing uses the player's CURRENT location, not the caller's stale struct",
         ctx do
      # an agent holds a story struct from before the player moved
      stale_story = ctx.story
      {:ok, _fresh} = Stories.move_player(ctx.story, ctx.shore.id)

      {:ok, message} =
        Stories.create_message(stale_story, %{
          kind: :say,
          content: "Down here, are you?",
          character_id: ctx.tosk.id,
          location_id: ctx.shore.id
        })

      assert message.witnessed_by_player == true
    end

    test "a nil location means everyone witnesses", ctx do
      {:ok, message} =
        Stories.create_message(ctx.story, %{kind: :narration, content: "Night falls."})

      assert message.witnessed_by_player == true
      assert ["Night falls."] = memory_contents(ctx.maren, 10)
      assert ["Night falls."] = memory_contents(ctx.tosk, 10)
    end
  end

  describe "fading_beats/2 and long-term memory" do
    test "fades chunk-aligned witnessed beats exactly once" do
      story = story_fixture()
      character = character_fixture(story)

      for n <- 1..5 do
        message_fixture(story, %{kind: :player, content: "beat #{n}"})
      end

      assert {:fade, beats, 2} = Stories.fading_beats(character, 2)
      assert Enum.map(beats, & &1.content) == ["beat 1", "beat 2"]

      {:ok, character} = Stories.append_character_memory(character, "I remember.", 2)
      assert [%{content: "I remember."}] = Stories.list_memories(character)
      assert :none = Stories.fading_beats(character, 2)

      # blocks append; they are never rewritten
      {:ok, character} = Stories.append_character_memory(character, "And then more.", 2)

      assert ["I remember.", "And then more."] =
               character |> Stories.list_memories() |> Enum.map(& &1.content)

      assert :none = Stories.fading_beats(character, 2)

      message_fixture(story, %{kind: :player, content: "beat 6"})

      assert {:fade, beats, 4} = Stories.fading_beats(character, 2)
      assert Enum.map(beats, & &1.content) == ["beat 3", "beat 4"]
    end
  end

  describe "avatars" do
    test "put_character_avatar/3 stores the image and broadcasts without the binary" do
      story = story_fixture()
      character = character_fixture(story)
      Stories.subscribe(story.id)

      assert {:ok, %Character{avatar_type: "image/jpeg"}} =
               Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")

      assert_receive {:character_updated, %Character{avatar_type: "image/jpeg", avatar: nil}}
      assert {<<255, 216, 255>>, "image/jpeg"} = Stories.get_avatar(character.id)
    end

    test "get_avatar/1 is nil for characters without a portrait" do
      story = story_fixture()
      character = character_fixture(story)

      assert Stories.get_avatar(character.id) == nil
    end

    test "updates from a stale struct never erase the portrait from broadcasts" do
      story = story_fixture()
      # this copy predates the portrait — exactly what a running agent holds
      character = character_fixture(story)
      {:ok, _} = Stories.put_character_avatar(character, <<255, 216, 255>>, "image/jpeg")

      Stories.subscribe(story.id)

      assert {:ok, %Character{avatar_type: "image/jpeg"}} =
               Stories.update_character_energy(character, 5)

      assert_receive {:character_updated,
                      %Character{energy: 5, avatar_type: "image/jpeg", avatar: nil}}
    end
  end

  describe "update_character_energy/2" do
    test "persists and broadcasts the new energy" do
      story = story_fixture()
      character = character_fixture(story, %{energy: 2})
      Stories.subscribe(story.id)

      assert {:ok, %Character{energy: 5}} = Stories.update_character_energy(character, 5)
      assert Stories.get_character!(character.id).energy == 5
      assert_receive {:character_updated, %Character{energy: 5}}
    end
  end
end
