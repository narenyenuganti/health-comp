-- User personal goals (lock when competitions start)
CREATE TABLE public.user_goals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    metric_type text NOT NULL,
    goal_value numeric NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, metric_type)
);

CREATE INDEX idx_user_goals_user ON public.user_goals (user_id);

ALTER TABLE public.user_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own goals"
    ON public.user_goals FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "Users can insert own goals"
    ON public.user_goals FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own goals"
    ON public.user_goals FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
