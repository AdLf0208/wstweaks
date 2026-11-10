// Runs at the head of `Game::native_loot_drops` (API 100): the mod's say on
// the drops being rolled. Only mob drops are touched (`context.entity` names
// the mob); block loot is left alone.
fn observe_loot_drops(
    game: &mut crate::game::Game<'_>,
    context: &NativeLootDrops<'_>,
    drops: &mut Vec<ItemStack>,
) {
    crate::game::wstweaks_state::on_loot_drops(game, context, drops);
}
