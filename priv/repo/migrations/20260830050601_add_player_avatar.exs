defmodule AgenticStories.Repo.Migrations.AddPlayerAvatar do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      # Hidden: used as a plate reference so the player keeps one face
      # across pictures. Never shown in the UI — the player is not a
      # character. load_in_query: false on the schema field; fetch with
      # Stories.get_player_avatar/1.
      add :player_avatar, :binary
      add :player_avatar_type, :string
    end
  end
end
