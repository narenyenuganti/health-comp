import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type ActivityRingSummaryRow,
  computeDailyScore,
  type HealthMetricRow,
  type ScoringFormula,
} from "./scoring.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface Competition {
  id: string;
  scoring_formula: ScoringFormula;
  start_date: string;
  end_date: string;
}

interface Participant {
  user_id: string;
  goal_snapshot: Record<string, number> | null;
  handicap_mult: number;
}

serve(async (_req: Request) => {
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  // Get all active competitions
  const { data: competitions, error: compError } = await supabase
    .from("competitions")
    .select("*")
    .eq("status", "active");

  if (compError) {
    return new Response(JSON.stringify({ error: compError.message }), { status: 500 });
  }

  const today = new Date().toISOString().split("T")[0];
  let scoresComputed = 0;

  for (const comp of competitions as Competition[]) {
    // Get participants
    const { data: participants } = await supabase
      .from("competition_participants")
      .select("*")
      .eq("competition_id", comp.id)
      .eq("status", "accepted");

    if (!participants) continue;

    for (const participant of participants as Participant[]) {
      // Get today's health metrics for this user
      const { data: metrics } = await supabase
        .from("health_metrics")
        .select("*")
        .eq("user_id", participant.user_id)
        .eq("date", today);

      if (!metrics) continue;

      let activityRingSummary: ActivityRingSummaryRow | null = null;
      if (comp.scoring_formula.kind === "apple_activity") {
        const { data: summaries } = await supabase
          .from("activity_ring_summaries")
          .select("*")
          .eq("user_id", participant.user_id)
          .eq("date", today)
          .limit(1);

        activityRingSummary = (summaries?.[0] ?? null) as ActivityRingSummaryRow | null;
      }

      const { metricScores, totalPoints } = computeDailyScore({
        formula: comp.scoring_formula,
        metrics: metrics as HealthMetricRow[],
        activityRingSummary,
        goalSnapshot: participant.goal_snapshot,
        handicapMult: Number(participant.handicap_mult ?? 1),
      });

      // Upsert daily score
      await supabase.from("daily_scores").upsert(
        {
          competition_id: comp.id,
          user_id: participant.user_id,
          date: today,
          metric_scores: metricScores,
          total_points: totalPoints,
        },
        { onConflict: "competition_id,user_id,date" }
      );

      scoresComputed++;
    }
  }

  return new Response(
    JSON.stringify({ success: true, scores_computed: scoresComputed }),
    { headers: { "Content-Type": "application/json" } }
  );
});
