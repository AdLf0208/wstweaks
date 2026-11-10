// Runs at the head of `Game::native_hurt_enemy` (API 39): a player's hit that
// landed while holding the Immolation Blade ignites the target, and the
// skeleton family is beheaded.
fn observe_hurt_enemy(
    game: &mut crate::game::Game<'_>,
    stack: &ItemStack,
    entity: u32,
    kind: &str,
) {
    crate::game::wstweaks_state::on_hurt_enemy(game, stack, entity, kind);
}
