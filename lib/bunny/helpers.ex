defmodule Bunny.Helpers do
  def retries(meta) do
    header(meta, "x-bunny-retries") || 0
  end

  def header(%{headers: :undefined}, _), do: nil
  def header(%{headers: headers}, key) do
    Enum.find_value headers, fn
      {^key, _, value}  -> value
      _                 -> nil
    end
  end
end
