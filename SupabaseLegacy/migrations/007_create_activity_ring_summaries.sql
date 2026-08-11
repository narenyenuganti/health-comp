-- Daily Activity Ring summaries synced from HealthKit HKActivitySummary.
-- Apple parity competitions use these values instead of reconstructing rings
-- from generic health_metrics rows.
CREATE TABLE public.activity_ring_summaries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    date date NOT NULL,
    move_value numeric NOT NULL DEFAULT 0,
    move_goal numeric NOT NULL DEFAULT 0,
    exercise_value numeric NOT NULL DEFAULT 0,
    exercise_goal numeric NOT NULL DEFAULT 0,
    stand_value numeric NOT NULL DEFAULT 0,
    stand_goal numeric NOT NULL DEFAULT 0,
    source text NOT NULL DEFAULT 'healthkit',
    synced_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, date, source)
);

CREATE INDEX idx_activity_ring_summaries_user_date
    ON public.activity_ring_summaries (user_id, date);

ALTER TABLE public.activity_ring_summaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own activity ring summaries"
    ON public.activity_ring_summaries FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1
            FROM public.friendships f
            WHERE f.status = 'accepted'
              AND (
                  (f.requester_id = auth.uid() AND f.receiver_id = activity_ring_summaries.user_id)
                  OR (f.receiver_id = auth.uid() AND f.requester_id = activity_ring_summaries.user_id)
              )
        )
    );

CREATE POLICY "Users can insert own activity ring summaries"
    ON public.activity_ring_summaries FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own activity ring summaries"
    ON public.activity_ring_summaries FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
