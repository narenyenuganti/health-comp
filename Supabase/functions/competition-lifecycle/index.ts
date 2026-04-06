import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (_req: Request) => {
  const supabase = createClient(supabaseUrl, supabaseServiceKey);
  const today = new Date().toISOString().split("T")[0];
  const results = { activated: 0, completed: 0, cancelled: 0 };

  // 1. Activate pending competitions where all participants accepted
  const { data: pendingComps } = await supabase
    .from("competitions")
    .select("id, start_date")
    .eq("status", "pending");

  for (const comp of pendingComps ?? []) {
    const { data: participants } = await supabase
      .from("competition_participants")
      .select("status")
      .eq("competition_id", comp.id);

    if (!participants || participants.length === 0) continue;

    const allAccepted = participants.every((p: any) => p.status === "accepted");
    const anyDeclined = participants.some((p: any) => p.status === "declined");

    if (allAccepted) {
      await supabase
        .from("competitions")
        .update({ status: "active" })
        .eq("id", comp.id);
      results.activated++;
    } else if (anyDeclined) {
      await supabase
        .from("competitions")
        .update({ status: "cancelled" })
        .eq("id", comp.id);
      results.cancelled++;
    }
    // If still pending invites, check if past 48hr deadline
    // (simplified: cancel if start_date has passed and not all accepted)
    else if (comp.start_date && comp.start_date < today) {
      await supabase
        .from("competitions")
        .update({ status: "cancelled" })
        .eq("id", comp.id);
      results.cancelled++;
    }
  }

  // 2. Complete active competitions past end_date
  const { data: activeComps } = await supabase
    .from("competitions")
    .select("id, end_date")
    .eq("status", "active");

  for (const comp of activeComps ?? []) {
    if (comp.end_date && comp.end_date < today) {
      // Get final scores
      const { data: scores } = await supabase
        .from("daily_scores")
        .select("user_id, total_points")
        .eq("competition_id", comp.id);

      // Aggregate total per user
      const userTotals: Record<string, number> = {};
      for (const score of scores ?? []) {
        userTotals[score.user_id] = (userTotals[score.user_id] ?? 0) + score.total_points;
      }

      await supabase
        .from("competitions")
        .update({ status: "completed" })
        .eq("id", comp.id);

      results.completed++;
    }
  }

  return new Response(
    JSON.stringify({ success: true, ...results }),
    { headers: { "Content-Type": "application/json" } }
  );
});
