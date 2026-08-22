defmodule AgenticStories.LLM.Response do
  @moduledoc """
  A provider-agnostic chat response. `text` joins the provider's text blocks;
  `stop_reason` and `usage` keep the provider's own vocabulary.
  """

  @enforce_keys [:text]
  defstruct [:text, :model, :stop_reason, usage: %{}]

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t() | nil,
          stop_reason: String.t() | nil,
          usage: map()
        }
end
