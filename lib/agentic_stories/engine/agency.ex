defmodule AgenticStories.Engine.Agency do
  @moduledoc """
  Whether a player's line is color or a bid, and who it is about.

  Color happens as written: talk, looking, sitting down. A bid reaches
  into someone else — it narrates what they do, or it takes, forces, or
  uses their body — and it is not true until that character's next beat
  says so.

  Decided in code. A classifier on every line would tax the common case,
  and an ambiguous line falls through as color: a missed bid is today's
  behavior, not a new failure. Narrating a named character needs no verb
  list, so it holds in whatever language the story is being told. The
  verb lists only catch a first-person bid ("I take her key") in English
  and Dutch.
  """

  alias AgenticStories.Stories.Character

  @type mode :: :bid | :color

  # Done to a person even with no pronoun: kissing, hitting, undressing.
  @onto_person ~r/\b(kiss(?:es|ed|ing)?|slap(?:s|ped)?|punch(?:es|ed)?|strangl\w*|chok(?:e|es|ed)|undress\w*|handcuff\w*|disarm\w*|grop(?:e|es|ed)|gag(?:s|ged)?|kus(?:t|te)?|zoen(?:t|de)?|slaat|sloeg|wurg\w*|uitkleed\w*|ontwapen\w*)\b/iu

  # Only counts when it lands on someone: "shoot the lock" is color,
  # "shoot Maren" and "grab her wrist" are not. "sla" is the Dutch slap,
  # kept out of the onto-list so it doesn't catch the English article-less
  # fragment inside longer words — it is matched here, whole.
  @at_person ~r/\b(shoot|shoots|shooting|shot|stab(?:s|bed)?|grab(?:s|bed)?|snatch(?:es|ed)?|steal|stole|stolen|seiz(?:e|es|ed)|tak(?:e|es|ing)|took|pull(?:s|ed)?|drag(?:s|ged)?|shov(?:e|es|ed)|rip(?:s|ped)?|pocket(?:s|ed)?|strip(?:s|ped)?|pin(?:s|ned)?|bind|binds|bound|forc(?:e|es|ed)|pak(?:t|te)?|grijp\w*|ruk(?:t|te)?|trek(?:t|ken)?|steel|stal|schiet|schoot|steek|steekt|stak|sla)\b/iu

  # Giving a secret or a thing over. "give up" / "give me a minute" are
  # excluded by handover?/1 — those are the player's own mood.
  @yield ~r/\b(confess\w*|admit(?:s|ted)?|agree[sd]?|obey[sd]?|surrender\w*|reveal[sd]?|beken\w*)\b/iu
  @handover ~r/\b(hand(?:s|ed)?|give|gives|gave|given|geef|geeft|gaf)\b/iu

  @compel ~r/\b(make|makes|made|order(?:s|ed)?|convinc\w*|dwing\w*|dwong|beveel\w*)\b/iu
  @third ~r/\b(she|her|hers|he|him|his|they|them|their|haar|hem|zij|hij|hen|hun|ze)\b/iu
  # "your" / "je" included: "I take your letter" is aimed at the addressee.
  @personish ~r/\b(she|her|hers|he|him|his|they|them|their|your|haar|hem|zij|hij|hen|hun|ze|je|jouw)\b/iu

  @skip ~w(and or the a an of to with for from about on in at by into onto over under van de het een met voor naar op uit bij en die dat who whose what which)
        |> Enum.uniq()
        |> Enum.join("|")

  @doc """
  `{:bid, ids}` when the line imposes an outcome on those present
  characters, otherwise `:color`. Ids follow `present`'s order.
  """
  @spec classify(String.t(), [Character.t()]) :: {:bid, [integer()]} | :color
  def classify(text, present) when is_binary(text) and is_list(present) do
    alone? = length(present) == 1

    case for %Character{id: id, name: name} <- present, target?(text, name, alone?), do: id do
      [] -> :color
      ids -> {:bid, ids}
    end
  end

  def classify(_text, _present), do: :color

  @doc """
  Who a line is about, and whether it is a bid.

  A bid's focus is its targets. Color focuses whoever is named, or the
  only person in the room; a group hello focuses no one.
  """
  @spec focus(String.t(), [Character.t()]) :: {[integer()], mode()}
  def focus(text, present) when is_binary(text) and is_list(present) do
    case classify(text, present) do
      {:bid, ids} -> {ids, :bid}
      :color -> {listeners(text, present), :color}
    end
  end

  def focus(_text, _present), do: {[], :color}

  defp listeners(text, present) do
    named = for %Character{id: id, name: name} <- present, named?(text, name), do: id

    cond do
      named != [] -> named
      match?([_], present) -> [hd(present).id]
      true -> []
    end
  end

  defp target?(text, name, alone?) do
    cond do
      narrates?(text, name) -> true
      named?(text, name) and imposes_on?(text, name) -> true
      alone? and imposes_here?(text) -> true
      true -> false
    end
  end

  # The name is the subject of a clause, not a vocative and not "ask Maren
  # about". "Maren and Brahm drop …" counts for both.
  defp narrates?(text, name) do
    escaped = Regex.escape(name)

    Regex.match?(~r/\b#{escaped}\s+(?!#{@skip}\b)\p{L}/iu, text) or
      Regex.match?(~r/\b#{escaped}\s+(?:and|en)\s+\p{L}/iu, text) or
      Regex.match?(~r/\b(?:and|en)\s+#{escaped}\s+(?!#{@skip}\b)\p{L}/iu, text)
  end

  defp imposes_on?(text, name) do
    onto_person?(text) or at_person_near?(text, name) or
      (confession?(text) and third_person?(text)) or
      (handover?(text) and (third_person?(text) or named?(text, name))) or
      compels?(text, name)
  end

  # No name to hang it on: only when one person is here, and only when the
  # line clearly lands on a person. "I grab a beer" does not.
  defp imposes_here?(text) do
    onto_person?(text) or
      (at_person?(text) and personish?(text)) or
      ((confession?(text) or handover?(text)) and third_person?(text)) or
      compels_someone?(text)
  end

  defp at_person_near?(text, name) do
    at_person?(text) and
      (personish?(text) or possessive?(text, name) or from_name?(text, name) or
         verb_on_name?(text, name))
  end

  # "shoot Maren", "pull Maren close" — not "take a seat next to Maren",
  # which has too many words between the verb and the name.
  defp verb_on_name?(text, name) do
    escaped = Regex.escape(name)

    Regex.match?(
      ~r/\b(?:shoot|shoots|shot|stab(?:s|bed)?|grab(?:s|bed)?|snatch(?:es|ed)?|steal|stole|seiz\w*|tak(?:e|es|ing)|took|pull(?:s|ed)?|drag(?:s|ged)?|shov\w*|rip(?:s|ped)?|pocket\w*|strip\w*|pin(?:s|ned)?|bind|binds|bound|forc\w*|pak\w*|grijp\w*|ruk\w*|trek\w*|steel|stal|schiet|schoot|steek\w*|stak|sla)\b(?:\s+\p{L}+){0,2}\s+#{escaped}\b/iu,
      text
    )
  end

  defp from_name?(text, name) do
    Regex.match?(
      ~r/\b(?:from|off|uit|van)\s+(?:\p{L}+\s+){0,5}#{Regex.escape(name)}\b/iu,
      text
    )
  end

  defp possessive?(text, name) do
    Regex.match?(~r/\b#{Regex.escape(name)}['’]s\b/iu, text)
  end

  defp compels?(text, name) do
    Regex.match?(
      ~r/#{@compel.source}.{0,40}\b(?:her|him|them|you|haar|hem|hen|#{Regex.escape(name)})\b/ius,
      text
    )
  end

  defp compels_someone?(text) do
    Regex.match?(~r/#{@compel.source}.{0,40}\b(?:her|him|them|you|haar|hem|hen)\b/ius, text)
  end

  defp named?(text, name), do: Regex.match?(~r/\b#{Regex.escape(name)}\b/iu, text)
  defp onto_person?(text), do: Regex.match?(@onto_person, text)
  defp at_person?(text), do: Regex.match?(@at_person, text)
  defp personish?(text), do: Regex.match?(@personish, text)
  defp third_person?(text), do: Regex.match?(@third, text)
  defp confession?(text), do: Regex.match?(@yield, text)

  # "give up" and "give me a minute" are the player's own mood, not a
  # handover of something the other person would have to accept.
  defp handover?(text) do
    Regex.match?(@handover, text) and not Regex.match?(~r/\bgive\s+(?:up|in|me\b)/iu, text)
  end
end
