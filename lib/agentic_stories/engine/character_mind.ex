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
         {:ok, decision} <- parse_decision(response.text, character.name) do
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

  @doc """
  Reads one reply as a beat. Characters write PROSE, not JSON — a small model
  writes a markedly better line when it is telling a story than when it is
  filling a string field — so the shape of the reply carries the kind:

      (empty, or "silence")            wait
      -> The Shore: she takes the      move
      "..." somewhere in the prose     say — someone spoke in this beat
      anything else                    act — a beat with nothing spoken

  Beats are third-person prose either way; the quotation marks are what tell
  a spoken beat from a silent one, and `:say` is what the collision guard and
  the chatter torch key on. A wholly asterisked line is still read as an act:
  it is the player's own convention and models reach for it.

  Two things are stripped before any of that: the character's own name, which
  a model will copy from the `Name: line` transcript format it has just been
  reading, and the leading dash the reading pane draws for itself.

  A reply that still arrives as a decision object is read as one. Models
  reach for JSON out of habit, and braces spilled into the story are worse
  than a little leniency here.
  """
  @spec parse_decision(String.t(), String.t() | nil) :: {:ok, decision()} | :error
  def parse_decision(text, name \\ nil)

  def parse_decision(text, name) when is_binary(text) do
    case text |> strip_prefix(name) |> String.trim() do
      "" -> {:ok, :wait}
      "{" <> _rest = object -> parse_object(object)
      prose -> {:ok, read_prose(prose)}
    end
  end

  def parse_decision(_text, _name), do: :error

  @move ~r/\A(?:->|=>|→)\s*([^:\n]+?)\s*(?::\s*(.*))?\z/s
  @gesture ~r/\A\*+\s*(.+?)\s*\*+\z/s
  @silence ~w(silence wait nothing none pass)

  defp read_prose(text) do
    cond do
      String.downcase(text) in @silence ->
        :wait

      match = Regex.run(@move, text) ->
        [destination | rest] = tl(match)
        {:move, String.trim(destination), List.first(rest) |> blank_to_nil()}

      match = Regex.run(@gesture, text) ->
        {:act, List.last(match)}

      spoken?(text) ->
        {:say, text}

      true ->
        {:act, text}
    end
  end

  # Quotation marks are the only signal that words were said out loud in a
  # beat that is otherwise narration. Two marks of any flavour will do —
  # a single stray one is punctuation, not speech.
  defp spoken?(text) do
    length(Regex.scan(~r/["“”«»]/u, text)) >= 2
  end

  # A model that has just read a transcript of "Maren: …" lines will write
  # one back. It is their own beat; the name is added again downstream.
  defp strip_prefix(text, nil), do: strip_dash(text)

  defp strip_prefix(text, name) do
    trimmed = String.trim(text)

    case String.split(trimmed, ":", parts: 2) do
      [head, rest] ->
        if String.trim(head) |> String.downcase() == String.downcase(name),
          do: strip_dash(rest),
          else: strip_dash(trimmed)

      _ ->
        strip_dash(trimmed)
    end
  end

  # the reading pane draws the dialogue dash itself
  defp strip_dash(text) do
    String.replace(text, ~r/\A\s*[—–]\s*/u, "")
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @spec parse_object(String.t()) :: {:ok, decision()} | :error
  defp parse_object(text) do
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
      or let it pass. Write only what you say or do, nothing else.
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
    Write your beat as the STORY tells it, not as yourself: third person,
    present tense, referring to yourself by name or as she/he/they. Never
    "I" outside of quotation marks — the player is the only "you" in this
    story, and you are one of the people it is told about. Inside quotation
    marks you speak in your own voice, first person, like anyone does. No
    name label in front, no asterisks around it:

        She takes the beer but doesn't open it yet, holding it against her
        thigh. "I'm looking for something I haven't found yet. That's the
        truth. What about you?"

    A beat with nothing in quotation marks is simply something you do, told
    the same way. Two other things you can write instead:

    - To go somewhere else, start the line with an arrow and the exact name
      of the place: -> The Shore: she takes the stairs two at a time
    - To stay quiet, write the single word: silence

    Stay quiet unless you have something that genuinely moves the scene.

    The scene remembers. Never re-describe where you are standing, what you
    are holding, what you are wearing, or what your face is doing when an
    earlier beat already showed it — least of all your own last beat. Start
    from what is already true and add something that was not there before.
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
