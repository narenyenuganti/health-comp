import {
  assertEquals,
} from "https://deno.land/std@0.177.0/testing/asserts.ts";
import {
  awardBadgesForResult,
  buildRivalryUpdate,
  computeCompetitionResult,
  orderedRivalryPair,
} from "./lifecycle.ts";

Deno.test("computeCompetitionResult reports winner and totals", () => {
  const result = computeCompetitionResult([
    { user_id: "user-a", total_points: 300 },
    { user_id: "user-b", total_points: 250 },
    { user_id: "user-a", total_points: 275 },
    { user_id: "user-b", total_points: 300 },
  ]);

  assertEquals(result.totalsByUser, { "user-a": 575, "user-b": 550 });
  assertEquals(result.winnerIds, ["user-a"]);
  assertEquals(result.isTie, false);
});

Deno.test("computeCompetitionResult handles ties", () => {
  const result = computeCompetitionResult([
    { user_id: "user-a", total_points: 300 },
    { user_id: "user-b", total_points: 300 },
  ]);

  assertEquals(result.winnerIds, ["user-a", "user-b"]);
  assertEquals(result.isTie, true);
});

Deno.test("orderedRivalryPair stores stable user order", () => {
  assertEquals(orderedRivalryPair("user-b", "user-a"), {
    userA: "user-a",
    userB: "user-b",
  });
});

Deno.test("buildRivalryUpdate increments wins and streaks", () => {
  const update = buildRivalryUpdate(
    {
      user_a: "user-a",
      user_b: "user-b",
      total_comps: 2,
      wins_a: 1,
      wins_b: 1,
      draws: 0,
      current_streak_user: "user-b",
      current_streak_count: 1,
      last_competed: "2026-05-01",
    },
    "user-a",
    "user-b",
    {
      totalsByUser: { "user-a": 575, "user-b": 550 },
      winnerIds: ["user-a"],
      isTie: false,
    },
    "2026-05-17",
  );

  assertEquals(update, {
    user_a: "user-a",
    user_b: "user-b",
    total_comps: 3,
    wins_a: 2,
    wins_b: 1,
    draws: 0,
    current_streak_user: "user-a",
    current_streak_count: 1,
    last_competed: "2026-05-17",
  });
});

Deno.test("buildRivalryUpdate increments draws and clears streak on tie", () => {
  const update = buildRivalryUpdate(
    null,
    "user-a",
    "user-b",
    {
      totalsByUser: { "user-a": 300, "user-b": 300 },
      winnerIds: ["user-a", "user-b"],
      isTie: true,
    },
    "2026-05-17",
  );

  assertEquals(update.draws, 1);
  assertEquals(update.current_streak_user, null);
  assertEquals(update.current_streak_count, 0);
});

Deno.test("awardBadgesForResult gives completion to both users and win to winners", () => {
  const awards = awardBadgesForResult({
    competitionId: "competition-1",
    participantIds: ["user-a", "user-b"],
    result: {
      totalsByUser: { "user-a": 575, "user-b": 550 },
      winnerIds: ["user-a"],
      isTie: false,
    },
    modeName: "apple_activity",
    dailyScores: [],
  });

  assertEquals(awards, [
    {
      user_id: "user-a",
      badge_id: "competition_complete",
      metadata: { competition_id: "competition-1", mode_name: "apple_activity" },
    },
    {
      user_id: "user-b",
      badge_id: "competition_complete",
      metadata: { competition_id: "competition-1", mode_name: "apple_activity" },
    },
    {
      user_id: "user-a",
      badge_id: "competition_win",
      metadata: { competition_id: "competition-1", mode_name: "apple_activity" },
    },
  ]);
});

Deno.test("awardBadgesForResult gives perfect week for seven capped Apple days", () => {
  const awards = awardBadgesForResult({
    competitionId: "competition-1",
    participantIds: ["user-a", "user-b"],
    result: {
      totalsByUser: { "user-a": 4200, "user-b": 3500 },
      winnerIds: ["user-a"],
      isTie: false,
    },
    modeName: "apple_activity",
    dailyScores: Array.from({ length: 7 }, (_, index) => ({
      user_id: "user-a",
      date: `2026-05-${String(index + 11).padStart(2, "0")}`,
      total_points: 600,
    })),
  });

  assertEquals(awards.some((award) => award.badge_id === "perfect_week"), true);
});
