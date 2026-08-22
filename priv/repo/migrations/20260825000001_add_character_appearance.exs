defmodule AgenticStories.Repo.Migrations.AddCharacterAppearance do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      # the visual source of truth: portraits and scene plates both draw on it
      add :appearance, :text
    end
  end
end
