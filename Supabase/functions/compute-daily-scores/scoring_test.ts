import { assertEquals } from "https://deno.land/std@0.177.0/testing/asserts.ts";
import { computeDailyScore } from "./scoring.ts";

Deno.test("weighted scoring preserves existing HealthComp formula behavior", () => {
  const result = computeDailyScore({
    formula: {
      kind: "weighted",
      metrics: [
        { type: "active_calories", weight: 0.4 },
        { type: "exercise_minutes", weight: 0.35 },
        { type: "stand_hours", weight: 0.25 },
      ],
      daily_cap: 600,
    },
    metrics: [
      { metric_type: "active_calories", value: 500 },
      { metric_type: "exercise_minutes", value: 30 },
      { metric_type: "stand_hours", value: 12 },
    ],
    goalSnapshot: {
      active_calories: 500,
      exercise_minutes: 30,
      stand_hours: 12,
    },
    handicapMult: 1,
  });

  assertEquals(result.metricScores, {
    active_calories: 40,
    exercise_minutes: 35,
    stand_hours: 25,
  });
  assertEquals(result.totalPoints, 100);
});

Deno.test("apple activity scoring adds ring percentages directly", () => {
  const result = computeDailyScore({
    formula: {
      kind: "apple_activity",
      metrics: [
        { type: "active_calories", weight: 1 },
        { type: "exercise_minutes", weight: 1 },
        { type: "stand_hours", weight: 1 },
      ],
      daily_cap: 600,
    },
    metrics: [
      { metric_type: "active_calories", value: 500 },
      { metric_type: "exercise_minutes", value: 30 },
      { metric_type: "stand_hours", value: 12 },
    ],
    goalSnapshot: {
      active_calories: 500,
      exercise_minutes: 30,
      stand_hours: 12,
    },
    handicapMult: 3,
  });

  assertEquals(result.metricScores, {
    active_calories: 100,
    exercise_minutes: 100,
    stand_hours: 100,
  });
  assertEquals(result.totalPoints, 300);
});

Deno.test("apple activity scoring prefers activity ring summaries", () => {
  const result = computeDailyScore({
    formula: {
      kind: "apple_activity",
      metrics: [
        { type: "active_calories", weight: 1 },
        { type: "exercise_minutes", weight: 1 },
        { type: "stand_hours", weight: 1 },
      ],
      daily_cap: 600,
    },
    metrics: [
      { metric_type: "active_calories", value: 500 },
      { metric_type: "exercise_minutes", value: 30 },
      { metric_type: "stand_hours", value: 12 },
    ],
    activityRingSummary: {
      move_value: 750,
      move_goal: 500,
      exercise_value: 60,
      exercise_goal: 30,
      stand_value: 18,
      stand_goal: 12,
    },
    goalSnapshot: {
      active_calories: 500,
      exercise_minutes: 30,
      stand_hours: 12,
    },
    handicapMult: 1,
  });

  assertEquals(result.metricScores, {
    active_calories: 150,
    exercise_minutes: 200,
    stand_hours: 150,
  });
  assertEquals(result.totalPoints, 500);
});

Deno.test("apple activity scoring does not require goal snapshots when ring summary exists", () => {
  const result = computeDailyScore({
    formula: {
      kind: "apple_activity",
      metrics: [
        { type: "active_calories", weight: 1 },
        { type: "exercise_minutes", weight: 1 },
        { type: "stand_hours", weight: 1 },
      ],
      daily_cap: 600,
    },
    metrics: [],
    activityRingSummary: {
      move_value: 500,
      move_goal: 500,
      exercise_value: 30,
      exercise_goal: 30,
      stand_value: 12,
      stand_goal: 12,
    },
    goalSnapshot: null,
    handicapMult: 1,
  });

  assertEquals(result.totalPoints, 300);
});

Deno.test("apple activity scoring caps each day at six hundred points", () => {
  const result = computeDailyScore({
    formula: {
      kind: "apple_activity",
      metrics: [
        { type: "active_calories", weight: 1 },
        { type: "exercise_minutes", weight: 1 },
        { type: "stand_hours", weight: 1 },
      ],
      daily_cap: 600,
    },
    metrics: [
      { metric_type: "active_calories", value: 250 },
      { metric_type: "exercise_minutes", value: 220 },
      { metric_type: "stand_hours", value: 200 },
    ],
    goalSnapshot: {
      active_calories: 100,
      exercise_minutes: 100,
      stand_hours: 100,
    },
    handicapMult: 1,
  });

  assertEquals(result.metricScores, {
    active_calories: 250,
    exercise_minutes: 220,
    stand_hours: 200,
  });
  assertEquals(result.totalPoints, 600);
});

Deno.test("apple activity missing ring data scores as zero", () => {
  const result = computeDailyScore({
    formula: {
      kind: "apple_activity",
      metrics: [
        { type: "active_calories", weight: 1 },
        { type: "exercise_minutes", weight: 1 },
        { type: "stand_hours", weight: 1 },
      ],
      daily_cap: 600,
    },
    metrics: [
      { metric_type: "active_calories", value: 500 },
    ],
    goalSnapshot: {
      active_calories: 500,
      exercise_minutes: 30,
      stand_hours: 12,
    },
    handicapMult: 1,
  });

  assertEquals(result.metricScores, {
    active_calories: 100,
    exercise_minutes: 0,
    stand_hours: 0,
  });
  assertEquals(result.totalPoints, 100);
});
