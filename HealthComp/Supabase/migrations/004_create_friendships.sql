-- Friendships between users
CREATE TABLE public.friendships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    receiver_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'blocked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(requester_id, receiver_id),
    CHECK (requester_id != receiver_id)
);

CREATE INDEX idx_friendships_requester ON public.friendships (requester_id);
CREATE INDEX idx_friendships_receiver ON public.friendships (receiver_id);
CREATE INDEX idx_friendships_status ON public.friendships (status);

ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;

-- Both parties can see their friendships
CREATE POLICY "Users can see own friendships"
    ON public.friendships FOR SELECT
    TO authenticated
    USING (requester_id = auth.uid() OR receiver_id = auth.uid());

-- Users can send friend requests
CREATE POLICY "Users can send friend requests"
    ON public.friendships FOR INSERT
    TO authenticated
    WITH CHECK (requester_id = auth.uid());

-- Either party can update (accept/block)
CREATE POLICY "Users can update own friendships"
    ON public.friendships FOR UPDATE
    TO authenticated
    USING (requester_id = auth.uid() OR receiver_id = auth.uid());

-- Either party can delete
CREATE POLICY "Users can delete own friendships"
    ON public.friendships FOR DELETE
    TO authenticated
    USING (requester_id = auth.uid() OR receiver_id = auth.uid());
