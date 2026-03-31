-- Competitions
CREATE TABLE public.competitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type text NOT NULL CHECK (type IN ('one_v_one', 'group', 'team')),
    mode_name text NOT NULL,
    scoring_formula jsonb NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'completed', 'cancelled')),
    start_date date,
    end_date date,
    created_by uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    handicap_enabled boolean NOT NULL DEFAULT false,
    stakes_text text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_competitions_status ON public.competitions (status);
CREATE INDEX idx_competitions_created_by ON public.competitions (created_by);

ALTER TABLE public.competitions ENABLE ROW LEVEL SECURITY;

-- Competition participants
CREATE TABLE public.competition_participants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    competition_id uuid NOT NULL REFERENCES public.competitions(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    team_id uuid,
    role text NOT NULL CHECK (role IN ('challenger', 'opponent', 'member')),
    status text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'accepted', 'declined')),
    goal_snapshot jsonb,
    handicap_mult numeric NOT NULL DEFAULT 1.0,
    joined_at timestamptz,
    UNIQUE(competition_id, user_id)
);

CREATE INDEX idx_participants_competition ON public.competition_participants (competition_id);
CREATE INDEX idx_participants_user ON public.competition_participants (user_id);

ALTER TABLE public.competition_participants ENABLE ROW LEVEL SECURITY;

-- Daily scores (computed server-side)
CREATE TABLE public.daily_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    competition_id uuid NOT NULL REFERENCES public.competitions(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    date date NOT NULL,
    metric_scores jsonb NOT NULL DEFAULT '{}',
    total_points numeric NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(competition_id, user_id, date)
);

CREATE INDEX idx_daily_scores_competition ON public.daily_scores (competition_id, date);

ALTER TABLE public.daily_scores ENABLE ROW LEVEL SECURITY;

-- RLS: Users can see competitions they participate in
CREATE POLICY "Participants can view competitions"
    ON public.competitions FOR SELECT
    TO authenticated
    USING (
        id IN (SELECT competition_id FROM public.competition_participants WHERE user_id = auth.uid())
        OR created_by = auth.uid()
    );

CREATE POLICY "Users can create competitions"
    ON public.competitions FOR INSERT
    TO authenticated
    WITH CHECK (created_by = auth.uid());

CREATE POLICY "Creator can update competition"
    ON public.competitions FOR UPDATE
    TO authenticated
    USING (created_by = auth.uid());

-- RLS: Participants
CREATE POLICY "Users can view own participations"
    ON public.competition_participants FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR competition_id IN (SELECT competition_id FROM public.competition_participants WHERE user_id = auth.uid())
    );

CREATE POLICY "Competition creator can add participants"
    ON public.competition_participants FOR INSERT
    TO authenticated
    WITH CHECK (
        competition_id IN (SELECT id FROM public.competitions WHERE created_by = auth.uid())
    );

CREATE POLICY "Participants can update own status"
    ON public.competition_participants FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid());

-- RLS: Daily scores visible to competition participants
CREATE POLICY "Participants can view scores"
    ON public.daily_scores FOR SELECT
    TO authenticated
    USING (
        competition_id IN (SELECT competition_id FROM public.competition_participants WHERE user_id = auth.uid())
    );

CREATE POLICY "System can insert scores"
    ON public.daily_scores FOR INSERT
    TO authenticated
    WITH CHECK (true);

CREATE POLICY "System can update scores"
    ON public.daily_scores FOR UPDATE
    TO authenticated
    USING (true);
