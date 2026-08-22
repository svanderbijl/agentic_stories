defmodule AgenticStories.LLM.Request do
  @moduledoc """
  A provider-agnostic chat request.

  A message's content is either a plain string or a list of text blocks.
  A block with `cache: true` asks the driver to place a cache breakpoint
  there: everything up to and including that block is a stable prefix the
  provider may reuse across calls. Drivers without caching ignore the flag.
  """

  @enforce_keys [:model, :messages]
  defstruct [:model, :system, :messages, max_tokens: 16_000]

  @type block :: %{text: String.t(), cache: boolean()}
  @type message :: %{role: :user | :assistant, content: String.t() | [block()]}
  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          messages: [message()],
          max_tokens: pos_integer()
        }
end
