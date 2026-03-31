# Social & Friends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the friends system — friendships table, friend requests, username search, invite links, and the Friends tab UI showing friend activity.

**Architecture:** Friendships stored in Supabase with RLS. FriendsClient TCA dependency for CRUD. FriendsFeature reducer manages the Friends tab with list, search, and detail views.

**Tech Stack:** Swift, SwiftUI, TCA, Supabase

**Spec:** `docs/superpowers/specs/2026-03-31-health-comp-design.md` — Section 3

---

## File Structure

```
HealthComp/Supabase/migrations/
│   └── 004_create_friendships.sql
HealthComp/HealthComp/
├── Models/
│   └── Friendship.swift
├── Features/
│   └── Friends/
│       ├── FriendsClient.swift
│       ├── FriendsFeature.swift
│       └── FriendsView.swift
HealthComp/HealthCompTests/
│   ├── FriendshipTests.swift
│   └── FriendsFeatureTests.swift
```

---

### Task 1: Friendships Table Migration

Create `HealthComp/Supabase/migrations/004_create_friendships.sql`.

### Task 2: Friendship Model (TDD)

Create `Friendship` struct — Codable, maps to friendships table. Test encode/decode.

### Task 3: FriendsClient Dependency (TDD)

TCA dependency with: `fetchFriends`, `sendRequest`, `acceptRequest`, `removeFriend`, `searchByUsername`.

### Task 4: FriendsFeature Reducer (TDD)

State: friends list, search query, pending requests. Actions: load, search, accept, decline, remove.

### Task 5: FriendsView UI

Friends list with activity rings, search bar, pending requests section. Wire into MainTab.

---
