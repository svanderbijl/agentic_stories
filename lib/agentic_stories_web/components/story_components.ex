defmodule AgenticStoriesWeb.StoryComponents do
  @moduledoc """
  Function components for the reading experience: the multiline composer
  input (Enter sends, Shift+Enter breaks the line), the typeset "beats" a
  story is made of, live relative timestamps, and the cast (chips, cards,
  and portraits).
  """

  use Phoenix.Component
  use AgenticStoriesWeb, :verified_routes

  alias AgenticStories.Stories.{Character, Location, Message}

  @doc """
  A chat-style multiline textarea. Enter submits the surrounding form,
  Shift+Enter inserts a newline, and the height grows with the text. The
  LiveView can push a `"composer:clear"` event to empty it after a send.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :rows, :string, default: "1"
  attr :placeholder, :string, default: nil
  attr :class, :string, default: nil

  def multiline_input(assigns) do
    ~H"""
    <textarea
      id={@id}
      name={@name}
      rows={@rows}
      phx-hook=".Composer"
      placeholder={@placeholder}
      class={@class}
    >{@value}</textarea>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          this.resize()
          this.el.addEventListener("input", () => this.resize())
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault()
              if (this.el.value.trim() !== "") this.el.form.requestSubmit()
            }
          })
          this.handleEvent("composer:clear", () => {
            this.el.value = ""
            this.resize()
            this.el.focus()
          })
        },
        updated() {
          this.resize()
        },
        resize() {
          this.el.style.height = "auto"
          this.el.style.height = Math.min(this.el.scrollHeight, 220) + "px"
        },
      }
    </script>
    """
  end

  @doc """
  A live relative timestamp ("just now", "3m ago"). Server-rendered once,
  then kept fresh client-side — streamed beats never re-render, so the
  updating has to happen in the browser.
  """
  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :class, :string, default: nil

  def time_ago(assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook=".TimeAgo"
      datetime={DateTime.to_iso8601(@at)}
      class={[
        "font-mono text-[9px] tracking-wide whitespace-nowrap text-ink-faint/80 select-none",
        @class
      ]}
    >{relative_time(@at)}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TimeAgo">
      export default {
        mounted() {
          this.tick()
          this.timer = setInterval(() => this.tick(), 30000)
        },
        updated() {
          this.tick()
        },
        destroyed() {
          clearInterval(this.timer)
        },
        tick() {
          const then = new Date(this.el.dateTime)
          const s = Math.max(0, Math.floor((Date.now() - then.getTime()) / 1000))
          this.el.textContent =
            s < 60 ? "just now"
            : s < 3600 ? `${Math.floor(s / 60)}m ago`
            : s < 86400 ? `${Math.floor(s / 3600)}h ago`
            : `${Math.floor(s / 86400)}d ago`
          this.el.title = then.toLocaleString()
        },
      }
    </script>
    """
  end

  def relative_time(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @doc """
  One beat of the story, typeset by kind: narration as book prose, dialogue
  as a script line under a small-caps name, actions as stage directions,
  and the player's words set off by an ember rule. Every beat carries a
  faint timestamp in its meta row.
  """
  attr :message, Message, required: true

  # The prose paragraphs are whitespace-pre-wrap, so their interpolations must
  # stay flush against the tags: phx-no-format keeps the formatter out.
  def beat(%{message: %Message{kind: :narration}} = assigns) do
    ~H"""
    <div class="beat beat--narration">
      <div class="flex justify-end">
        <.beat_time message={@message} />
      </div>
      <p
        class="beat-body font-serif text-[1.0625rem] leading-[1.85] whitespace-pre-wrap text-ink"
        phx-no-format
      >{@message.content}</p>
    </div>
    """
  end

  def beat(%{message: %Message{kind: :say}} = assigns) do
    ~H"""
    <div class="beat beat--say">
      <div class="flex items-baseline justify-between gap-3">
        <p class="font-mono text-[10px] tracking-[0.25em] text-ember/90 uppercase">
          {speaker(@message)}
        </p>
        <.beat_time message={@message} />
      </div>
      <p
        class="mt-1 font-serif text-[1.0625rem] leading-[1.8] whitespace-pre-wrap text-ink"
        phx-no-format
      ><span class="mr-1 text-ink-faint" aria-hidden="true">—</span>{@message.content}</p>
    </div>
    """
  end

  def beat(%{message: %Message{kind: :act}} = assigns) do
    ~H"""
    <div class="beat beat--act">
      <div class="flex items-baseline justify-between gap-3">
        <p class="font-mono text-[10px] tracking-[0.25em] text-ink-faint uppercase">
          <span class="text-ember/70" aria-hidden="true">✳</span> {speaker(@message)}
        </p>
        <.beat_time message={@message} />
      </div>
      <p
        class="mt-1 font-serif text-[1rem] leading-[1.8] whitespace-pre-wrap text-ink-soft italic"
        phx-no-format
      >{@message.content}</p>
    </div>
    """
  end

  def beat(%{message: %Message{kind: :player}} = assigns) do
    ~H"""
    <div class="beat beat--player border-l-2 border-ember/60 pl-4">
      <div class="flex items-baseline justify-between gap-3">
        <p class="font-mono text-[10px] tracking-[0.25em] text-ink-faint uppercase">You</p>
        <.beat_time message={@message} />
      </div>
      <p
        class="mt-1 font-serif text-[1.0625rem] leading-[1.8] whitespace-pre-wrap text-ink"
        phx-no-format
      >{@message.content}</p>
    </div>
    """
  end

  def beat(%{message: %Message{kind: :illustration}} = assigns) do
    ~H"""
    <figure class="beat beat--illustration my-2">
      <div class="flex justify-end">
        <.beat_time message={@message} />
      </div>
      <img
        src={~p"/plates/#{@message.id}"}
        alt={@message.content}
        loading="lazy"
        class="mx-auto mt-1 max-h-[26rem] w-full rounded-xl border border-edge object-cover shadow-sm"
      />
      <figcaption class="mt-2 text-center font-serif text-[13px] text-ink-soft italic">
        {@message.content}
      </figcaption>
    </figure>
    """
  end

  defp beat_time(assigns) do
    ~H"""
    <.time_ago id={"beat-#{@message.id}-at"} at={@message.inserted_at} />
    """
  end

  @doc """
  A character's portrait if one has been painted, otherwise an
  initial-letter mark in the same round frame.
  """
  attr :character, Character, required: true
  attr :class, :string, default: "size-8"

  def avatar(%{character: %Character{avatar_type: type}} = assigns) when is_binary(type) do
    ~H"""
    <img
      src={~p"/avatars/#{@character.id}"}
      alt={"Portrait of #{@character.name}"}
      loading="lazy"
      class={["shrink-0 rounded-full border border-edge object-cover", @class]}
    />
    """
  end

  def avatar(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "grid shrink-0 place-items-center rounded-full border border-edge bg-ember-soft",
        "font-display font-semibold text-ember",
        @class
      ]}
    >
      {String.first(@character.name)}
    </span>
    """
  end

  @doc """
  A cast member's name with a presence dot: the brighter the ember, the more
  energy the character has left. Characters who are elsewhere fade — you only
  know where someone is when they're with you.
  """
  attr :character, Character, required: true
  attr :max_energy, :integer, required: true
  attr :here, :boolean, default: true
  attr :thinking, :boolean, default: false

  def cast_chip(assigns) do
    ~H"""
    <span
      class={[
        "flex items-center gap-1.5 font-mono text-[10px] tracking-[0.18em] text-ink-soft uppercase",
        !@here && "opacity-50"
      ]}
      title={@character.persona}
    >
      <.avatar character={@character} class="size-4 text-[8px]" />
      {@character.name}
      <span :if={@thinking} class="animate-pulse text-ember" aria-label="thinking">✎</span>
      <span
        :if={@here && !@thinking}
        class="size-1.5 rounded-full bg-ember transition-opacity duration-700"
        style={"opacity: #{presence(@character, @max_energy)}"}
      ></span>
    </span>
    """
  end

  @doc """
  The full introduction to a cast member: portrait, name, presence, who they
  are, and how they talk.
  """
  attr :character, Character, required: true
  attr :max_energy, :integer, required: true
  attr :here, :boolean, default: true
  attr :thinking, :boolean, default: false

  def cast_card(assigns) do
    ~H"""
    <div class={["rounded-xl border border-edge bg-paper-raised p-4", !@here && "opacity-75"]}>
      <div class="flex items-center gap-3">
        <.avatar character={@character} class="size-12 text-lg" />
        <div class="min-w-0">
          <h3 class="truncate font-display text-base font-semibold text-ink">
            {@character.name}
          </h3>
          <p
            :if={@here}
            class="mt-0.5 flex items-center gap-1.5 font-mono text-[9px] tracking-[0.18em] text-ink-faint uppercase"
          >
            <span
              class="size-1.5 rounded-full bg-ember transition-opacity duration-700"
              style={"opacity: #{presence(@character, @max_energy)}"}
            ></span>
            <span :if={!@thinking}>with you</span>
            <span :if={@thinking} class="animate-pulse text-ember">✎ about to…</span>
          </p>
          <p
            :if={!@here}
            class="mt-0.5 font-mono text-[9px] tracking-[0.18em] text-ink-faint/70 uppercase"
          >
            elsewhere
          </p>
        </div>
      </div>
      <p class="mt-3 font-serif text-[13px] leading-relaxed text-ink-soft">
        {@character.persona}
      </p>
      <p
        :if={@character.voice}
        class="mt-2 font-serif text-[12px] leading-relaxed text-ink-faint italic"
      >
        {@character.voice}
      </p>
    </div>
    """
  end

  @doc """
  A place in the story's world: where you are, or somewhere you could go.
  """
  attr :location, Location, required: true
  attr :here, :boolean, required: true
  attr :movable, :boolean, default: true

  def location_card(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border p-3",
      (@here && "border-ember/40 bg-ember-soft") || "border-edge bg-paper-raised"
    ]}>
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-display text-sm font-semibold text-ink">{@location.name}</h3>
        <span
          :if={@here}
          class="shrink-0 font-mono text-[9px] tracking-[0.18em] text-ember uppercase"
        >
          you are here
        </span>
        <button
          :if={!@here && @movable}
          phx-click="go"
          phx-value-id={@location.id}
          class="shrink-0 cursor-pointer font-mono text-[9px] tracking-[0.18em] text-ink-faint uppercase transition-colors hover:text-ember"
        >
          go <span aria-hidden="true">→</span>
        </button>
      </div>
      <p :if={@location.description} class="mt-1 font-serif text-[12px] leading-relaxed text-ink-soft">
        {@location.description}
      </p>
    </div>
    """
  end

  defp presence(%Character{energy: energy}, max_energy) do
    Float.round(0.25 + 0.75 * min(energy, max_energy) / max_energy, 2)
  end

  defp speaker(%Message{character: %Character{name: name}}), do: name
  # a characterless act is the player's deed
  defp speaker(%Message{kind: :act}), do: "You"
  defp speaker(%Message{}), do: "Someone"
end
