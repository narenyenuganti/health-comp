-- Health metrics synced from user devices
CREATE TABLE public.health_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    metric_type text NOT NULL,
    value numeric NOT NULL,
    date date NOT NULL,
    source text NOT NULL DEFAULT 'healthkit',
    synced_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, metric_type, date, source)
);

-- Indexes for common queries
CREATE INDEX idx_health_metrics_user_date ON public.health_metrics (user_id, date);
CREATE INDEX idx_health_metrics_user_type_date ON public.health_metrics (user_id, metric_type, date);

-- Row Level Security
ALTER TABLE public.health_metrics ENABLE ROW LEVEL SECURITY;

-- Users can only read their own metrics
CREATE POLICY "Users can read own metrics"
    ON public.health_metrics FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- Users can insert their own metrics
CREATE POLICY "Users can insert own metrics"
    ON public.health_metrics FOR INSERT
    TO authenticated
    WITH CHECK (user_id = auth.uid());

-- Users can update their own metrics (upsert on sync)
CREATE POLICY "Users can update own metrics"
    ON public.health_metrics FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
