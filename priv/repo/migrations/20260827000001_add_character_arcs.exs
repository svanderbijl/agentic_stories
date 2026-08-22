defmodule AgenticStories.Repo.Migrations.AddCharacterArcs do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      # where this character's own story could go — never shown to the player
      add :arc, :text
    end
  end
end
