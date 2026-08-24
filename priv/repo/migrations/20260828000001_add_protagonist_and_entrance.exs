defmodule AgenticStories.Repo.Migrations.AddProtagonistAndEntrance do
  use Ecto.Migration

  def change do
    # Who the player is, in the fiction. The seed said it; until now only the
    # Weaver ever read it, and the cast was left to guess.
    alter table(:stories) do
      add :protagonist, :text
    end

    # Which figure in the opening narration this character is. Without it a
    # character placed at the opening location reads the second-person
    # narration and assumes the player's role.
    alter table(:characters) do
      add :entrance, :text
    end
  end
end
