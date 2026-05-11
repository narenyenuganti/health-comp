export type DailyScoreRow = {
  user_id: string;
  date?: string;
  total_points: number;
};

export type CompetitionResult = {
  totalsByUser: Record<string, number>;
  winnerIds: string[];
  isTie: boolean;
};

export type RivalryRow = {
  user_a: string;
  user_b: string;
  total_comps: number;
  wins_a: number;
  wins_b: number;
  draws: number;
  current_streak_user: string | null;
  current_streak_count: number;
  last_competed: string | null;
};

export type UserBadgeInsert = {
  user_id: string;
  badge_id: string;
  metadata: {
    competition_id: string;
    mode_name: string;
  };
};

export function computeCompetitionResult(scores: DailyScoreRow[]): CompetitionResult {
  const totalsByUser = scores.reduce<Record<string, number>>((totals, score) => {
    totals[score.user_id] = (totals[score.user_id] ?? 0) + Number(score.total_points);
    return totals;
  }, {});

  const totals = Object.values(totalsByUser);
  const winningTotal = totals.length === 0 ? 0 : Math.max(...totals);
  const winnerIds = Object.entries(totalsByUser)
    .filter(([, total]) => total === winningTotal)
    .map(([userId]) => userId)
    .sort();

  return {
    totalsByUser,
    winnerIds,
    isTie: winnerIds.length > 1,
  };
}

export function orderedRivalryPair(
  firstUserId: string,
  secondUserId: string,
): { userA: string; userB: string } {
  return firstUserId < secondUserId
    ? { userA: firstUserId, userB: secondUserId }
    : { userA: secondUserId, userB: firstUserId };
}

export function buildRivalryUpdate(
  existing: RivalryRow | null,
  userA: string,
  userB: string,
  result: CompetitionResult,
  completedDate: string,
): RivalryRow {
  const winnerId = result.isTie ? null : result.winnerIds[0] ?? null;
  const previousStreakUser = existing?.current_streak_user ?? null;
  const previousStreakCount = existing?.current_streak_count ?? 0;

  return {
    user_a: userA,
    user_b: userB,
    total_comps: (existing?.total_comps ?? 0) + 1,
    wins_a: (existing?.wins_a ?? 0) + (winnerId === userA ? 1 : 0),
    wins_b: (existing?.wins_b ?? 0) + (winnerId === userB ? 1 : 0),
    draws: (existing?.draws ?? 0) + (result.isTie ? 1 : 0),
    current_streak_user: winnerId,
    current_streak_count: winnerId == null
      ? 0
      : previousStreakUser === winnerId
      ? previousStreakCount + 1
      : 1,
    last_competed: completedDate,
  };
}

export function awardBadgesForResult(input: {
  competitionId: string;
  participantIds: string[];
  result: CompetitionResult;
  modeName: string;
  dailyScores: DailyScoreRow[];
}): UserBadgeInsert[] {
  const metadata = {
    competition_id: input.competitionId,
    mode_name: input.modeName,
  };
  const awards: UserBadgeInsert[] = input.participantIds.map((userId) => ({
    user_id: userId,
    badge_id: "competition_complete",
    metadata,
  }));

  if (!input.result.isTie) {
    awards.push(
      ...input.result.winnerIds.map((userId) => ({
        user_id: userId,
        badge_id: "competition_win",
        metadata,
      })),
    );
  }

  for (const userId of input.participantIds) {
    if (hasPerfectAppleWeek(userId, input.modeName, input.dailyScores)) {
      awards.push({
        user_id: userId,
        badge_id: "perfect_week",
        metadata,
      });
    }
  }

  return awards;
}

function hasPerfectAppleWeek(
  userId: string,
  modeName: string,
  dailyScores: DailyScoreRow[],
): boolean {
  if (modeName !== "apple_activity") return false;

  const perfectDays = new Set(
    dailyScores
      .filter((score) => score.user_id === userId && Number(score.total_points) >= 600)
      .map((score) => score.date)
      .filter(Boolean),
  );

  return perfectDays.size >= 7;
}
