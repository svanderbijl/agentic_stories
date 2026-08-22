defmodule AgenticStories.Repo.Migrations.AddCharacterAvatars do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :avatar, :binary
      add :avatar_type, :string
    end
  end
end
