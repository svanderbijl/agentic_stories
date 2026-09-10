defmodule AgenticStories.LLM.JSON do
  @moduledoc """
  Lenient JSON extraction for LLM output.

  Models are asked to answer with a single JSON object, but they occasionally
  wrap it in code fences or prose. `decode_object/1` finds the outermost
  `{...}` span and decodes it.
  """

  @spec decode_object(String.t()) :: {:ok, map()} | :error
  def decode_object(text) when is_binary(text) do
    with {:ok, slice} <- outer_object(text) do
      case Jason.decode(slice) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> decode_repaired(slice)
      end
    end
  end

  # Models often leave a trailing comma before } or ]; one pass is enough
  # for typical nested objects. Anything still invalid stays :error.
  defp decode_repaired(slice) do
    case slice |> String.replace(~r/,(\s*[}\]])/, "\\1") |> Jason.decode() do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end

  defp outer_object(text) do
    with {first, _} <- :binary.match(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}"),
         {last, _} when last >= first <- List.last(closes) do
      {:ok, :binary.part(text, first, last - first + 1)}
    else
      _ -> :error
    end
  end
end
