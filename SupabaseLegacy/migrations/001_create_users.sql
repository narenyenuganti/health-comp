-- Users profile table (extends Supabase auth.users)
CREATE TABLE public.users (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username text UNIQUE NOT NULL,
    display_name text NOT NULL,
    avatar_url text,
    bio text,
    cosmetics jsonb NOT NULL DEFAULT '{}',
    cp_balance integer NOT NULL DEFAULT 0,
    cp_lifetime integer NOT NULL DEFAULT 0,
    privacy jsonb NOT NULL DEFAULT '{
        "profileVisibility": "public",
        "activityVisibility": "friendsOnly",
        "discoverableByContacts": true
    }',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_users_username ON public.users (username);

-- Row Level Security
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Anyone can read public profiles
CREATE POLICY "Public profiles are viewable by authenticated users"
    ON public.users FOR SELECT
    TO authenticated
    USING (
        privacy->>'profileVisibility' = 'public'
        OR id = auth.uid()
    );

-- Users can insert their own profile (on first sign-in)
CREATE POLICY "Users can insert own profile"
    ON public.users FOR INSERT
    TO authenticated
    WITH CHECK (id = auth.uid());

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
    ON public.users FOR UPDATE
    TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- Username uniqueness check function (callable before insert to give nice errors)
CREATE OR REPLACE FUNCTION public.is_username_available(desired_username text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM public.users WHERE username = lower(desired_username)
    );
$$;
