defmodule AgenticStories.Imagery do
  @moduledoc """
  The provider port for image generation, mirroring `AgenticStories.LLM`:
  all image traffic flows through `generate/1`, which dispatches to the
  configured adapter. Used to paint character avatars.

  Avatars are a nice-to-have — when `enabled?/0` is false (the test default,
  or no adapter configured) callers must simply skip them.
  """

  @type image :: %{binary: binary(), content_type: String.t()}

  @callback generate(prompt :: String.t()) :: {:ok, image()} | {:error, term()}
  @callback compose(prompt :: String.t(), references :: [image()]) ::
              {:ok, image()} | {:error, term()}

  @spec generate(String.t()) :: {:ok, image()} | {:error, term()}
  def generate(prompt) when is_binary(prompt), do: adapter().generate(prompt)

  @doc """
  Generates a scene using up to three reference images (character portraits),
  so the people in the plate are the people on the cast cards.
  """
  @spec compose(String.t(), [image()]) :: {:ok, image()} | {:error, term()}
  def compose(prompt, references) when is_binary(prompt) and is_list(references) do
    adapter().compose(prompt, Enum.take(references, 3))
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled, false) and adapter() != nil
  end

  defp adapter, do: Keyword.get(config(), :adapter)
  defp config, do: Application.get_env(:agentic_stories, __MODULE__, [])
end
