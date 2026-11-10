-- Campus default themes from the ProPresenter theme files (Nov 2026).
UPDATE campuses SET default_theme_id = 'ns'     WHERE id IN ('north', 'south');
UPDATE campuses SET default_theme_id = 'east'   WHERE id IN ('east', 'tauranga');
UPDATE campuses SET default_theme_id = 'chapel' WHERE id = 'chapel';
