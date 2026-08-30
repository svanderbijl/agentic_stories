defmodule AgenticStories.Repo.Migrations.AddPlayerAppearance do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      # How the player looks NOW in the fiction. Nil means use `protagonist`
      # (the woven description). A plate that reads the record writes this
      # so the next plate does not revert to the opening clothes.
      add :player_appearance, :text
    end
  end
end
