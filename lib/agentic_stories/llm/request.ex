defmodule AgenticStories.LLM.Request do
  @moduledoc """
  A provider-agnostic chat request.

  A message's content is either a plain string or a list of text blocks.
  A block with `cache: true` asks the driver to place a cache breakpoint
  there: everything up to and including that block is a stable prefix the
  provider may reuse across calls. Drivers without caching ignore the flag.

  Consecutive messages may share a role — the engine sends one user message
  per story beat. Every driver folds such a run into ONE wire turn, blocks
  in order: Anthropic rejects consecutive same-role messages outright, and
  the chat templates behind the OpenAI-compatible providers wrap each
  message in turn markers — a small model handed hundreds of one-line user
  turns comes apart.
  """

  @enforce_keys [:model, :messages]
  defstruct [:model, :system, :messages, :temperature, max_tokens: 16_000]

  @type block :: %{text: String.t(), cache: boolean()}
  @type message :: %{role: :user | :assistant, content: String.t() | [block()]}
  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          messages: [message()],
          temperature: float() | nil,
          max_tokens: pos_integer()
        }
end
