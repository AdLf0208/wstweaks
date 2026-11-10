// Runs at the head of `Game::native_server_about_to_start` (API 44): reads
// `config/wstweaks.toml` before the worlds open.
fn observe_server_about_to_start(game: &mut crate::game::Game<'_>) {
    crate::game::wstweaks_state::on_server_about_to_start(game);
}
