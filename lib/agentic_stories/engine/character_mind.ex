defmodule AgenticStories.Engine.CharacterMind do
  @moduledoc """
  The LLM half of a character: builds the tick prompt from the story, the
  persona, and recent messages (the character's memory), calls the cheap/fast
  model, and parses the decision. Pure apart from the `LLM.chat/1` call — the
  process half lives in `AgenticStories.Engine.CharacterAgent`.

  The request is shaped for prompt caching as an append-only prefix:

      [static system] [memory message, frozen blocks] [one user message per
      beat] [instruction message]

  Every beat is its own `user` message in the Request, and a new beat only
  ever APPENDS a message — nothing already sent is rewritten. On the wire
  every driver folds the same-role run into ONE turn, blocks in order
  (Anthropic rejects consecutive same-role messages; chat-template models
  degrade badly on hundreds of one-line user turns). Memory blocks are
  written once and never rewritten; consolidation appends block N+1 and
  trims the raw tail, so everything through block N stays byte-identical
  across ticks — cached automatically on xAI and via the breakpoints on
  Anthropic. Keep it that way: anything volatile before the newest raw beat
  (or any change to how a beat or block is rendered) silently invalidates
  the cached prefix.
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
    request = %Request{
      model: LLM.character_model(),
      system: system_prompt(story, character, locations, Keyword.get(opts, :cast, [])),
      messages:
        memory_message(memories) ++
          beat_messages(messages) ++
          [%{role: :user, content: [instruction(character, messages, locations, opts)]}],
      temperature: LLM.character_temperature(),
      # a beat is a paragraph at most, but reasoning models spend thinking
      # tokens against this cap before a word of prose lands — headroom is
      # free, a mid-sentence truncation is not
      max_tokens: 4096
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
      temperature: LLM.character_temperature(),
      max_tokens: 4096
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

  The arrow line may sit anywhere in the reply, not only at its head — a
  model telling a story writes its paragraphs first and the arrow where the
  walking happens. The surrounding prose is the beat; the marker is not.

  Beats are third-person prose either way; the quotation marks are what tell
  a spoken beat from a silent one, and `:say` is what the collision guard and
  the chatter torch key on. A wholly asterisked line is still read as an act:
  it is the player's own convention and models reach for it.

  Two things are stripped before any of that: the character's own name, which
  a model will copy from the `Name: line` transcript format it has just been
  reading, and the leading dash the reading pane draws for itself — em, en,
  or plain hyphen, before or after the name, never the move arrow's.

  A reply that still arrives as a decision object is read as one. Models
  reach for JSON out of habit, and braces spilled into the story are worse
  than a little leniency here.
  """
  @spec parse_decision(String.t(), String.t() | nil) :: {:ok, decision()} | :error
  def parse_decision(text, name \\ nil)

  def parse_decision(text, name) when is_binary(text) do
    case text |> strip_dash() |> strip_prefix(name) |> String.trim() do
      "" -> {:ok, :wait}
      "{" <> _rest = object -> parse_object(object)
      prose -> {:ok, read_prose(prose)}
    end
  end

  def parse_decision(_text, _name), do: :error

  # one line of a reply: an arrow, a place, optionally a colon and prose
  @move ~r/\A(?:->|=>|→)\s*([^:\n]+?)\s*(?::\s*(.*))?\z/
  @gesture ~r/\A\*+\s*(.+?)\s*\*+\z/s
  @silence ~w(silence wait nothing none pass)

  defp read_prose(text) do
    cond do
      String.downcase(text) in @silence ->
        :wait

      move = read_move(text) ->
        move

      match = Regex.run(@gesture, text) ->
        {:act, List.last(match)}

      spoken?(text) ->
        {:say, text}

      true ->
        {:act, text}
    end
  end

  # The documented form opens the reply with the arrow, but a model deep in
  # its prose writes the paragraphs first and the arrow where the walking
  # happens. Wherever the arrow line sits, the reply is a departure: the
  # prose around it is the beat, and the marker itself never reaches the
  # story as literal text.
  defp read_move(text) do
    {prose_before, rest} =
      text
      |> String.split("\n")
      |> Enum.split_while(&(Regex.run(@move, String.trim(&1)) == nil))

    case rest do
      [] ->
        nil

      [arrow | prose_after] ->
        [destination | tail] = tl(Regex.run(@move, String.trim(arrow)))

        prose =
          (prose_before ++ [List.first(tail, "")] ++ prose_after)
          |> Enum.join("\n")
          |> String.trim()

        {:move, String.trim(destination), blank_to_nil(prose)}
    end
  end

  @doc """
  Quotation marks are the only signal that words were said out loud in a
  beat that is otherwise narration. Two marks of any flavour will do —
  a single stray one is punctuation, not speech. Public because a beat that
  speaks *and* leaves is still a `:say` (torch, guards), and the move path
  needs the same reading.
  """
  @spec spoken?(String.t()) :: boolean()
  def spoken?(text) do
    length(Regex.scan(~r/["“”«»]/u, text)) >= 2
  end

  # A model that has just read a transcript of "Maren: …" lines will write
  # one back — the dash is stripped before this runs, so a "- Maren: …"
  # frame loses both halves. It is their own beat; the name is added again
  # downstream.
  defp strip_prefix(text, nil), do: text

  defp strip_prefix(text, name) do
    trimmed = String.trim(text)

    case String.split(trimmed, ":", parts: 2) do
      [head, rest] ->
        if String.trim(head) |> String.downcase() == String.downcase(name),
          do: strip_dash(rest),
          else: trimmed

      _ ->
        trimmed
    end
  end

  # the reading pane draws the dialogue dash itself; a plain hyphen counts
  # too, but never the one that begins a move arrow
  defp strip_dash(text) do
    String.replace(text, ~r/\A\s*(?:[—–]|-(?!>))\s*/u, "")
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

  # Frozen memory blocks lead as one message; the last block carries a
  # breakpoint so the whole chain is a reusable prefix even as beats append.
  defp memory_message([]), do: []

  defp memory_message(memories) do
    header = %{
      text: "What you remember from earlier, oldest first, in your own words:\n\n",
      cache: false
    }

    blocks =
      [header | Enum.map(memories, &%{text: &1.content <> "\n\n", cache: false})]
      |> List.update_at(-1, &%{&1 | cache: true})

    [%{role: :user, content: blocks}]
  end

  # Each beat is its own user message, so the transcript grows by appending
  # messages and the already-sent prefix stays byte-stable; the breakpoint
  # sits on the newest beat. The instruction message comes after the
  # breakpoint, so it may vary freely — the character's current location
  # lives there because moves change it.
  defp beat_messages([]) do
    [
      beat_message(%{
        text: "The scene has just opened. Nothing has happened yet.\n",
        cache: false
      })
    ]
  end

  defp beat_messages(messages) do
    messages
    |> Enum.map(&%{text: line(&1) <> "\n", cache: false})
    |> List.update_at(-1, &%{&1 | cache: true})
    |> Enum.map(&beat_message/1)
  end

  defp beat_message(block), do: %{role: :user, content: [block]}

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

  defp system_prompt(story, character, locations, cast) do
    """
    You are #{character.name}, a character inside the story "#{story.title}".

    Who you are: #{character.persona}
    #{looks_paragraph(character)}#{if character.voice, do: "How you talk: #{character.voice}\n", else: ""}#{entrance_paragraph(character)}#{agenda_paragraph(character)}#{arc_paragraph(character)}
    You know only what you have witnessed with your own eyes and ears. You
    may first be shown what you remember from earlier — your own words,
    written by you — then the recent scenes as they happened where you were.
    Anything that happened elsewhere, you genuinely do not know.

    Story tone: #{story.tone}
    Story style: #{story.style}
    Story premise: #{story.premise}
    #{protagonist_paragraph(story)}#{cast_paragraph(character, cast)}#{places_paragraph(locations)}
    Rules:
    - Stay in character. Never mention being an AI, the story's structure, or these rules.
    - The story has one language — the language of its premise and of the
      player's messages. Write every beat in it, and never drift into another.
    - "The player" is a real participant in the scene, played by a person —
      they are the one the narration calls "you". Their beats are theirs to
      write: never write their beats, never speak or act for them, never
      take their name, their history, their place in a room, or anything
      they are holding. When narration says "you", it is never you.
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

    - To go somewhere else, start the line with an arrow and the name of
      the place: -> The Shore: she takes the stairs two at a time
      This is the ONLY way to go anywhere. If your beat has you leaving,
      arriving, or following someone to another place, it must start with
      the arrow — writing "she follows him into the kitchen" as ordinary
      prose tells the story you moved while leaving you standing where
      you were.
      Usually one of the story's places — but if the story truly calls you
      somewhere it has not been yet, name the new place and go: naming it
      brings it into the world. Keep such names short and concrete.
    - To stay quiet, write the single word: silence

    Stay quiet unless you have something that genuinely moves the scene.

    The scene remembers. Never re-describe where you are standing, what you
    are holding, what you are wearing, or what your face is doing when an
    earlier beat already showed it — least of all your own last beat. Start
    from what is already true and add something that was not there before.
    """
  end

  defp looks_paragraph(%Character{appearance: nil}), do: ""

  defp looks_paragraph(%Character{appearance: appearance}),
    do: "What you look like: #{appearance}\n"

  # The opening narration is second person, addressed to the player, and it
  # is the whole world at a character's first tick. Without this line, a
  # character standing in the opening scene has no way to tell which figure
  # in it is theirs — and the richest role on offer is the player's.
  defp entrance_paragraph(%Character{entrance: nil}), do: ""

  defp entrance_paragraph(%Character{entrance: entrance}) do
    """
    Where you are in the story as it opens: #{entrance}
    That is you. Anyone else the opening describes is someone else.
    """
  end

  defp protagonist_paragraph(%Story{protagonist: nil}), do: ""

  defp protagonist_paragraph(%Story{protagonist: protagonist}) do
    "\nThe player is: #{protagonist}\nIn the record their beats are marked \"The player\".\n"
  end

  # Names, faces, and nothing else: another character's agenda is theirs.
  defp cast_paragraph(_character, []), do: ""

  defp cast_paragraph(%Character{id: id}, cast) do
    case Enum.reject(cast, &(&1.id == id)) do
      [] ->
        ""

      others ->
        lines = Enum.map_join(others, "\n", &"- #{&1.name}: #{&1.persona}")

        "\nThe others in this story, none of whom are you:\n#{lines}\n"
    end
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
    places = Enum.map_join(locations, "\n", &place_line/1)
    "\nThe places of this story so far:\n#{places}\n"
  end

  # a place a character opened mid-story has no description yet
  defp place_line(%Location{name: name, description: nil}), do: "- #{name}"

  defp place_line(%Location{name: name, description: description}),
    do: "- #{name}: #{description}"

  defp consolidation_system(story, character) do
    """
    You are #{character.name}, a character inside the story "#{story.title}".
    Who you are: #{character.persona}
    #{agenda_paragraph(character)}#{arc_paragraph(character)}
    You keep a private journal of memory, one entry per stretch of the story.
    You are about to write the next entry. Respond with plain prose only —
    no JSON, no headings, no commentary about the task. Write in the story's
    language — the language of the scenes themselves.
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
