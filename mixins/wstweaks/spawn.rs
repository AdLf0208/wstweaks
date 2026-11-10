// Runs at the head of `Game::native_mob_spawned` (API 4): a skeleton that
// spawned in the Nether is replaced by a wither skeleton at the same spot.
fn observe_mob_spawned(
    game: &mut crate::game::Game<'_>,
    dimension: &str,
    kind: &str,
    pos: [f64; 3],
) {
    crate::game::wstweaks_state::on_mob_spawned(game, dimension, kind, pos);
}
