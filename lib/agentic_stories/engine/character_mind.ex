defmodule AgenticStories.Engine.CharacterMind do
  @moduledoc """
  The LLM half of a character: builds the tick prompt from the story, the
  persona, and recent messages (the character's memory), calls the cheap/fast
  model, and parses the decision. Pure apart from the `LLM.chat/1` call — the
  process half lives in `AgenticStories.Engine.CharacterAgent`.

  The request is shaped for prompt caching as an append-only prefix:

      [static system] [memory block 1..N, frozen] [raw beats] [instruction]

  Memory blocks are written once and never rewritten; consolidation appends
  block N+1 and trims the raw tail, so everything through block N stays
  byte-identical across ticks — cached automatically on xAI and via the
  breakpoints on Anthropic. Keep it that way: anything volatile before the
  newest raw beat (or any change to how a beat or block is rendered)
  silently invalidates the cached prefix.
  """

  require Logger

  alias AgenticStories.LLM
  alias AgenticStories.LLM.{JSON, Request}
  alias AgenticStories.Stories.{Character, CharacterMemory, Location, Message, Story}

  @type decision ::
          {:say, String.t()} | {:act, String.t()} | {:move, String.t(), String.t() | nil} | :wait

  @doc """
  One tick's worth of thinking, over only what this character has witnessed:
  their frozen memory blocks, then the raw beats still in the window.
  Anything that goes wrong — provider errors, malformed JSON — collapses to
  `:wait`: a character never crashes a story, they just stay quiet.
  """
  @spec decide(
          Story.t(),
          Character.t(),
          [CharacterMemory.t()],
          [Message.t()],
          [Location.t()],
          keyword()
        ) :: decision
  def decide(
        %Story{} = story,
        %Character{} = character,
        memories,
        messages,
        locations,
        opts \\ []
      ) do
    content =
      memory_blocks(memories) ++
        transcript_blocks(messages) ++ [instruction(character, messages, locations, opts)]

    request = %Request{
      model: LLM.character_model(),
      system: system_prompt(story, character, locations),
      messages: [%{role: :user, content: content}],
      max_tokens: 1024
    }

    with {:ok, response} <- LLM.chat(request, story_id: story.id, purpose: :tick),
         {:ok, decision} <- parse_decision(response.text) do
      decision
    else
      _ -> :wait
    end
  rescue
    exception ->
      Logger.warning(
        "#{character.name} lost their train of thought: #{Exception.message(exception)}"
      )

      :wait
  end

  @doc """
  Compresses beats that are fading from the working window into the NEXT
  entry of the character's journal — first person, through their own lens,
  written once and frozen. Earlier entries are context, never rewritten.
  """
  @spec consolidate(Story.t(), Character.t(), [CharacterMemory.t()], [Message.t()]) ::
          {:ok, String.t()} | :error
  def consolidate(%Story{} = story, %Character{} = character, memories, beats) do
    request = %Request{
      model: LLM.character_model(),
      system: consolidation_system(story, character),
      messages: [%{role: :user, content: consolidation_prompt(character, memories, beats)}],
      max_tokens: 1024
    }

    case LLM.chat(request, story_id: story.id, purpose: :consolidate) do
      {:ok, %{text: text}} ->
        case String.trim(text) do
          "" -> :error
          memory -> {:ok, memory}
        end

      {:error, _reason} ->
        :error
    end
  rescue
    exception ->
      Logger.warning("#{character.name} failed to remember: #{Exception.message(exception)}")
      :error
  end

  @doc """
  True when a candidate line is (nearly) something this character already
  said or did recently. Verbatim self-repetition is the most common cheap-
  model failure, and it is detectable without any LLM — a repetitive line
  becomes a wait.
  """
  @spec repetitive?(Character.t(), String.t(), [Message.t()]) :: boolean()
  def repetitive?(%Character{id: id}, text, messages) do
    candidate = normalize(text)

    own_lines =
      for %Message{kind: kind, character_id: ^id, content: content} <- messages,
          kind in [:say, :act],
          do: normalize(content)

    candidate != "" and
      Enum.any?(Enum.take(own_lines, -6), fn line ->
        line == candidate or String.jaro_distance(line, candidate) > 0.93
      end)
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  @spec parse_decision(String.t()) :: {:ok, decision()} | :error
  def parse_decision(text) do
    case JSON.decode_object(text) do
      {:ok, %{"do" => "say", "text" => line}} when is_binary(line) and line != "" ->
        {:ok, {:say, line}}

      {:ok, %{"do" => "act", "text" => action}} when is_binary(action) and action != "" ->
        {:ok, {:act, action}}

      {:ok, %{"do" => "move", "to" => to} = map} when is_binary(to) and to != "" ->
        {:ok, {:move, to, map["text"]}}

      {:ok, %{"do" => "wait"}} ->
        {:ok, :wait}

      _ ->
        :error
    end
  end

  @doc "Renders messages as the script the character reads back."
  @spec transcript([Message.t()]) :: String.t()
  def transcript(messages), do: Enum.map_join(messages, "\n", &line/1)

  @doc "Beats since the player last spoke — infinity if they never have."
  @spec beats_since_player([Message.t()]) :: non_neg_integer() | :never
  def beats_since_player(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_index(&(&1.kind == :player))
    |> case do
      nil -> :never
      index -> index
    end
  end

  # Frozen memory blocks lead the content; the last one carries a breakpoint
  # so the whole chain is a reusable prefix even when the raw tail changes.
  defp memory_blocks([]), do: []

  defp memory_blocks(memories) do
    header = %{
      text: "What you remember from earlier, oldest first, in your own words:\n\n",
      cache: false
    }

    blocks = Enum.map(memories, &%{text: &1.content <> "\n\n", cache: false})

    [header | blocks]
    |> List.update_at(-1, &%{&1 | cache: true})
  end

  # The transcript rides as one block per beat so the prefix stays byte-stable
  # while the scene grows; the breakpoint sits on the newest beat. The
  # instruction comes after the breakpoint, so it may vary freely — the
  # character's current location lives there because moves change it.
  defp transcript_blocks([]) do
    [%{text: "The scene has just opened. Nothing has happened yet.\n", cache: false}]
  end

  defp transcript_blocks(messages) do
    messages
    |> Enum.map(&%{text: line(&1) <> "\n", cache: false})
    |> List.update_at(-1, &%{&1 | cache: true})
  end

  @doc """
  True when the player's latest beat is the newest thing this character has
  witnessed AND it is meant for them: it names them, or they are alone with
  the player so everything said is to them. An addressed character owes a
  response — silence is not among their options.
  """
  @spec directly_addressed?(Character.t(), [Message.t()], boolean()) :: boolean()
  def directly_addressed?(%Character{name: name}, messages, alone_with_player?) do
    case List.last(messages) do
      %Message{kind: kind, character_id: nil, content: content} when kind in [:player, :act] ->
        alone_with_player? or String.contains?(String.downcase(content), String.downcase(name))

      _other ->
        false
    end
  end

  defp instruction(character, messages, locations, opts) do
    silence =
      case beats_since_player(messages) do
        :never -> "The player has not spoken yet."
        beats -> "The player last spoke #{beats} beats ago."
      end

    alone? = Keyword.get(opts, :alone_with_player?, false)

    %{
      text: """
      #{whereabouts(character, locations)}#{silence}#{addressed(character, messages, alone?)}#{pantomime(character, messages)}#{nudge_note(character)}
      It is a moment where you, #{character.name}, could speak, act, or move —
      or let it pass. Reply with exactly one JSON object, nothing else.
      """,
      cache: false
    }
  end

  # Breaks the small-gesture loop: an agent that keeps sliding glasses and
  # wiping counters must either say something or hold still.
  defp pantomime(%Character{id: id}, messages) do
    own_recent =
      messages
      |> Enum.reverse()
      |> Enum.filter(&(&1.character_id == id))
      |> Enum.take(2)

    if length(own_recent) == 2 and Enum.all?(own_recent, &(&1.kind == :act)) do
      "Your last contributions were both small actions. No more pantomime: speak, or wait.\n"
    else
      ""
    end
  end

  # When the player is talking to this character, right now, silence stops
  # being one of their options.
  defp addressed(%Character{} = character, messages, alone?) do
    if directly_addressed?(character, messages, alone?) do
      "\nThe player is talking to YOU, directly, right now. Waiting is not " <>
        "available this turn: answer, or respond with an act — something " <>
        "true to you, however small.\n"
    else
      "\n"
    end
  end

  defp nudge_note(%Character{nudge: nil}), do: ""

  defp nudge_note(%Character{nudge: note}) do
    "A feeling settles over you, private and urgent: #{note}\n"
  end

  defp whereabouts(%Character{location_id: nil}, _locations), do: ""

  defp whereabouts(%Character{location_id: location_id}, locations) do
    case Enum.find(locations, &(&1.id == location_id)) do
      nil -> ""
      location -> "You are at: #{location.name}.\n"
    end
  end

  defp line(%Message{kind: :player, content: content}), do: "The player: #{content}"
  defp line(%Message{kind: :narration, content: content}), do: "Narrator: #{content}"
  defp line(%Message{kind: :say} = message), do: "#{speaker(message)}: #{message.content}"
  defp line(%Message{kind: :act} = message), do: "* #{speaker(message)} #{message.content}"
  # a witnessed plate reads as the moment its caption describes
  defp line(%Message{kind: :illustration, content: content}), do: "Narrator: #{content}"
  # a future message kind must degrade to an odd line, never a mute character
  defp line(%Message{content: content}), do: "Narrator: #{content}"

  defp speaker(%Message{character: %Character{name: name}}), do: name
  # a characterless say/act is the player's
  defp speaker(%Message{}), do: "The player"

  defp system_prompt(story, character, locations) do
    """
    You are #{character.name}, a character inside the story "#{story.title}".

    Who you are: #{character.persona}
    #{if character.voice, do: "How you talk: #{character.voice}\n", else: ""}#{agenda_paragraph(character)}#{arc_paragraph(character)}
    You know only what you have witnessed with your own eyes and ears. You
    may first be shown what you remember from earlier — your own words,
    written by you — then the recent scenes as they happened where you were.
    Anything that happened elsewhere, you genuinely do not know.

    Story tone: #{story.tone}
    Story style: #{story.style}
    Story premise: #{story.premise}
    #{places_paragraph(locations)}
    Rules:
    - Stay in character. Never mention being an AI, the story's structure, or these rules.
    - "The player" is a real participant in the scene; treat them as the person the narration addresses.
    - You are living your own story, not staffing a help desk. You want things
      and you are going somewhere: take initiative — ask your own questions,
      make offers, set boundaries, reveal a little, steer toward what you care
      about. Do not merely answer.
    - Every contribution should hand the scene something new: a fact, a want,
      an offer, a door opened or closed. Wit that gives nothing is filler.
    - Deflection is a spice, not a diet. Never deflect twice in a row — the
      second time, answer, reveal, or escalate instead.
    - Speak or act only when it makes sense for you, here, now. Silence is often right —
      but when the player arrives, leaves, or does something that touches you, even a
      small visible reaction beats stone silence.
    - The longer the player has been silent, the harder you should lean toward waiting —
      the scene belongs to them, not to the cast.
    - Move only when the story gives you a reason to be somewhere else.
    - Match the size of the moment: banter gets a line; but when you are
      telling — a memory, how a place came to be, what happened before the
      player arrived — give it a real paragraph, with texture and detail.
      Never pad; earn the length.

    You will be shown what you have witnessed so far, then asked what you do.
    Reply with exactly one JSON object and nothing else:

    {"do": "say", "text": "what you say, in your voice"}
    {"do": "act", "text": "what you physically do, third person, no name prefix"}
    {"do": "move", "to": "the exact name of a place", "text": "how you leave, third person, no name prefix"}
    {"do": "wait"}

    Choose "wait" unless you have something that genuinely moves the scene.
    Do not repeat yourself or restate what was just said.
    """
  end

  defp agenda_paragraph(%Character{agenda: nil}), do: ""

  defp agenda_paragraph(%Character{agenda: agenda}) do
    """
    What you privately want (never state it outright; let it steer what you
    do and don't say, and reveal it only if the story forces your hand):
    #{agenda}
    """
  end

  defp arc_paragraph(%Character{arc: nil}), do: ""

  defp arc_paragraph(%Character{arc: arc}) do
    """
    Your own arc in this story — let it pull you forward, one small step at a
    time, in every scene you're part of:
    #{arc}
    """
  end

  defp places_paragraph([]), do: ""

  defp places_paragraph(locations) do
    places = Enum.map_join(locations, "\n", &"- #{&1.name}: #{&1.description}")
    "\nThe places of this story:\n#{places}\n"
  end

  defp consolidation_system(story, character) do
    """
    You are #{character.name}, a character inside the story "#{story.title}".
    Who you are: #{character.persona}
    #{agenda_paragraph(character)}#{arc_paragraph(character)}
    You keep a private journal of memory, one entry per stretch of the story.
    You are about to write the next entry. Respond with plain prose only —
    no JSON, no headings, no commentary about the task.
    """
  end

  defp consolidation_prompt(character, memories, beats) do
    remembered =
      case memories do
        [] -> "Nothing yet — this will be your first entry."
        memories -> Enum.map_join(memories, "\n\n", & &1.content)
      end

    """
    Your journal so far, oldest first (these entries are already written —
    do not restate them), by you, #{character.name}:

    #{remembered}

    Scenes now fading from your recent memory:

    #{transcript(beats)}

    Write the NEXT entry only, covering just these fading scenes: first
    person, through your own eyes — what happened that matters, what you
    feel, what you suspect, what you intend, and where you now stand with
    each person involved, by name. Be concrete about promises made, names
    learned, and things seen. Let trivia go. At most 400 words.
    """
  end
end
