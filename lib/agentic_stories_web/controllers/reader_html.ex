defmodule AgenticStoriesWeb.ReaderHTML do
  use AgenticStoriesWeb, :html

  alias AgenticStories.Stories.{Character, Message}

  def show(assigns) do
    ~H"""
    <div class="min-h-dvh bg-paper">
      <nav class="flex items-center justify-between px-5 py-3 sm:px-8 print:hidden">
        <.link
          navigate={~p"/stories/#{@story}"}
          class="font-mono text-[10px] tracking-[0.2em] text-ink-faint uppercase transition-colors hover:text-ember"
        >
          &larr; back to the story
        </.link>
        <span class="font-mono text-[10px] tracking-[0.2em] text-ink-faint/70 uppercase">
          print for keeps
        </span>
      </nav>

      <article class="mx-auto max-w-2xl px-5 pt-16 pb-24 sm:px-8">
        <header class="text-center">
          <p class="font-mono text-[10px] tracking-[0.3em] text-ink-faint uppercase">
            Agentic Stories presents
          </p>
          <h1 class="mt-4 font-display text-4xl leading-tight font-semibold tracking-tight text-ink sm:text-5xl">
            {@story.title}
          </h1>
          <p class="mt-4 font-serif text-lg leading-relaxed text-ink-soft italic">
            {@story.premise}
          </p>
          <p class="mt-3 font-mono text-[10px] tracking-[0.2em] text-ink-faint lowercase">
            {@story.tone}
          </p>
          <div class="mx-auto mt-10 h-px w-24 bg-edge"></div>
        </header>

        <div class="mt-12 space-y-6">
          <.passage :for={beat <- @beats} message={beat} />
        </div>

        <footer :if={@story.status == :finished} class="mt-16">
          <div class="flex items-center gap-4">
            <div class="h-px w-full bg-edge"></div>
            <span class="shrink-0 font-mono text-[10px] tracking-[0.3em] text-ember uppercase">
              The end
            </span>
            <div class="h-px w-full bg-edge"></div>
          </div>
        </footer>
      </article>
    </div>
    """
  end

  attr :message, Message, required: true

  defp passage(%{message: %Message{kind: :narration}} = assigns) do
    ~H"""
    <p class="font-serif text-[1.0625rem] leading-[1.9] whitespace-pre-wrap text-ink" phx-no-format>{@message.content}</p>
    """
  end

  defp passage(%{message: %Message{kind: kind}} = assigns) when kind in [:say, :player] do
    ~H"""
    <p class="font-serif text-[1.0625rem] leading-[1.9] whitespace-pre-wrap text-ink" phx-no-format>“{@message.content}” <span class="font-mono text-[10px] tracking-[0.2em] text-ink-faint uppercase">— {reader_speaker(@message)}</span></p>
    """
  end

  defp passage(%{message: %Message{kind: :act}} = assigns) do
    ~H"""
    <p
      class="font-serif text-[1rem] leading-[1.9] whitespace-pre-wrap text-ink-soft italic"
      phx-no-format
    >{reader_speaker(@message)} {@message.content}</p>
    """
  end

  defp passage(%{message: %Message{kind: :illustration}} = assigns) do
    ~H"""
    <figure class="my-10">
      <img
        src={~p"/plates/#{@message.id}"}
        alt={@message.content}
        class="mx-auto w-full rounded-xl border border-edge object-cover"
      />
      <figcaption class="mt-3 text-center font-serif text-[13px] text-ink-soft italic">
        {@message.content}
      </figcaption>
    </figure>
    """
  end

  defp reader_speaker(%Message{kind: :player}), do: "You"
  defp reader_speaker(%Message{character: %Character{name: name}}), do: name
  defp reader_speaker(%Message{}), do: "You"
end
