-- Badge definitions
CREATE TABLE public.badge_definitions (
    id text PRIMARY KEY,
    name text NOT NULL,
    description text NOT NULL,
    category text NOT NULL CHECK (category IN ('competition', 'streak', 'milestone')),
    icon_name text NOT NULL,
    requirement jsonb NOT NULL
);

-- User earned badges
CREATE TABLE public.user_badges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    badge_id text NOT NULL REFERENCES public.badge_definitions(id),
    earned_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb
);

CREATE INDEX idx_user_badges_user ON public.user_badges (user_id);

ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own badges"
    ON public.user_badges FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "System can insert badges"
    ON public.user_badges FOR INSERT
    TO authenticated
    WITH CHECK (true);

-- Cosmetic definitions
CREATE TABLE public.cosmetic_definitions (
    id text PRIMARY KEY,
    name text NOT NULL,
    category text NOT NULL CHECK (category IN ('avatar', 'frame', 'theme')),
    cp_cost integer NOT NULL,
    preview_url text,
    rarity text NOT NULL CHECK (rarity IN ('common', 'rare', 'epic', 'legendary'))
);

-- User owned cosmetics
CREATE TABLE public.user_cosmetics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    cosmetic_id text NOT NULL REFERENCES public.cosmetic_definitions(id),
    purchased_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, cosmetic_id)
);

CREATE INDEX idx_user_cosmetics_user ON public.user_cosmetics (user_id);

ALTER TABLE public.user_cosmetics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own cosmetics"
    ON public.user_cosmetics FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "Users can purchase cosmetics"
    ON public.user_cosmetics FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

-- Rivalries (materialized from competition results)
CREATE TABLE public.rivalries (
    user_a uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    user_b uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    total_comps integer NOT NULL DEFAULT 0,
    wins_a integer NOT NULL DEFAULT 0,
    wins_b integer NOT NULL DEFAULT 0,
    draws integer NOT NULL DEFAULT 0,
    current_streak_user uuid,
    current_streak_count integer NOT NULL DEFAULT 0,
    last_competed date,
    PRIMARY KEY(user_a, user_b)
);

ALTER TABLE public.rivalries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own rivalries"
    ON public.rivalries FOR SELECT
    TO authenticated
    USING (user_a = auth.uid() OR user_b = auth.uid());

-- Seed badge definitions
INSERT INTO public.badge_definitions (id, name, description, category, icon_name, requirement) VALUES
    ('competition_win', 'Competition Win', 'Win a competition', 'competition', 'trophy.fill', '{"type": "competition_win", "count": 1}'),
    ('competition_complete', 'Competition Complete', 'Complete a competition (win or lose)', 'competition', 'checkmark.circle.fill', '{"type": "competition_complete", "count": 1}'),
    ('rivalry_dominator', 'Rivalry Dominator', 'Win 5+ competitions against the same person', 'competition', 'flame.fill', '{"type": "rivalry_wins", "count": 5}'),
    ('perfect_week', 'Perfect Week', 'Score max points every day in a competition', 'competition', 'star.fill', '{"type": "perfect_week"}'),
    ('comeback_king', 'Comeback King', 'Win after trailing at halfway', 'competition', 'arrow.up.circle.fill', '{"type": "comeback_win"}'),
    ('team_mvp', 'Team MVP', 'Highest scorer on the winning team', 'competition', 'person.3.fill', '{"type": "team_mvp"}'),
    ('on_fire', 'On Fire', '3 competition win streak', 'streak', 'flame.fill', '{"type": "win_streak", "count": 3}'),
    ('unstoppable', 'Unstoppable', '5 competition win streak', 'streak', 'bolt.fill', '{"type": "win_streak", "count": 5}'),
    ('legendary', 'Legendary', '10 competition win streak', 'streak', 'crown.fill', '{"type": "win_streak", "count": 10}'),
    ('iron_will', 'Iron Will', 'Complete 10 competitions', 'milestone', 'shield.fill', '{"type": "competition_complete", "count": 10}'),
    ('veteran', 'Veteran', 'Complete 50 competitions', 'milestone', 'medal.fill', '{"type": "competition_complete", "count": 50}'),
    ('first_blood', 'First Blood', 'Complete your first competition', 'milestone', 'play.fill', '{"type": "competition_complete", "count": 1}'),
    ('social_butterfly', 'Social Butterfly', 'Compete with 10 different people', 'milestone', 'person.2.wave.2.fill', '{"type": "unique_opponents", "count": 10}'),
    ('all_rounder', 'All-Rounder', 'Win in every preset mode', 'milestone', 'circle.grid.3x3.fill', '{"type": "win_all_presets"}'),
    ('night_owl', 'Night Owl', 'Win a Sleep Challenge', 'milestone', 'moon.fill', '{"type": "win_mode", "mode": "sleep_challenge"}');

-- Read-only badge definitions for all authenticated users
ALTER TABLE public.badge_definitions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read badge definitions"
    ON public.badge_definitions FOR SELECT
    TO authenticated
    USING (true);

-- Read-only cosmetic definitions
ALTER TABLE public.cosmetic_definitions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read cosmetic definitions"
    ON public.cosmetic_definitions FOR SELECT
    TO authenticated
    USING (true);
