export interface ScoringMetric {
  type: string;
  weight: number;
}

export interface ScoringFormula {
  kind?: "weighted" | "apple_activity";
  metrics: ScoringMetric[];
  daily_cap: number | null;
}

export interface HealthMetricRow {
  metric_type: string;
  value: number;
}

export interface ActivityRingSummaryRow {
  move_value: number;
  move_goal: number;
  exercise_value: number;
  exercise_goal: number;
  stand_value: number;
  stand_goal: number;
}

export interface ComputeDailyScoreInput {
  formula: ScoringFormula;
  metrics: HealthMetricRow[];
  activityRingSummary?: ActivityRingSummaryRow | null;
  goalSnapshot: Record<string, number> | null;
  handicapMult: number;
}

export interface ComputeDailyScoreResult {
  metricScores: Record<string, number>;
  totalPoints: number;
}

export function computeDailyScore(input: ComputeDailyScoreInput): ComputeDailyScoreResult {
  if (input.formula.kind === "apple_activity") {
    return computeAppleActivityScore(input);
  }

  return computeWeightedScore(input);
}

function computeAppleActivityScore(input: ComputeDailyScoreInput): ComputeDailyScoreResult {
  const metricScores: Record<string, number> = {};
  let totalPoints = 0;

  for (const scoringMetric of input.formula.metrics) {
    const rawPercent = appleActivityPercent(input, scoringMetric.type);
    const points = roundOneDecimal(rawPercent);
    metricScores[scoringMetric.type] = points;
    totalPoints += rawPercent;
  }

  return {
    metricScores,
    totalPoints: capAndRound(totalPoints, input.formula.daily_cap ?? 600),
  };
}

function computeWeightedScore(input: ComputeDailyScoreInput): ComputeDailyScoreResult {
  const metricScores: Record<string, number> = {};
  let totalPoints = 0;

  for (const scoringMetric of input.formula.metrics) {
    const rawPercent = percentOfGoal(input, scoringMetric.type);
    const weightedPoints = rawPercent * scoringMetric.weight * input.handicapMult;
    metricScores[scoringMetric.type] = roundOneDecimal(weightedPoints);
    totalPoints += weightedPoints;
  }

  return {
    metricScores,
    totalPoints: capAndRound(totalPoints, input.formula.daily_cap),
  };
}

function appleActivityPercent(input: ComputeDailyScoreInput, metricType: string): number {
  const summary = input.activityRingSummary;

  if (!summary) {
    return percentOfGoal(input, metricType);
  }

  switch (metricType) {
    case "active_calories":
      return percent(summary.move_value, summary.move_goal);
    case "exercise_minutes":
      return percent(summary.exercise_value, summary.exercise_goal);
    case "stand_hours":
      return percent(summary.stand_value, summary.stand_goal);
    default:
      return percentOfGoal(input, metricType);
  }
}

function percentOfGoal(input: ComputeDailyScoreInput, metricType: string): number {
  const actualValue = input.metrics.find((metric) => metric.metric_type === metricType)?.value ?? 0;
  const goalValue = input.goalSnapshot?.[metricType] ?? 100;

  return percent(actualValue, goalValue);
}

function percent(value: number, goal: number): number {
  if (goal <= 0) {
    return 0;
  }

  return (value / goal) * 100;
}

function capAndRound(points: number, cap: number | null): number {
  const capped = cap == null ? points : Math.min(points, cap);
  return roundOneDecimal(Math.max(0, capped));
}

function roundOneDecimal(value: number): number {
  return Math.round(value * 10) / 10;
}
