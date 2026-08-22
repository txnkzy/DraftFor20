/**
 * Six badges, all of them a threshold on a number the profile already shows.
 *
 * Deliberately small and deliberately boring: no levels, no points, no
 * progress bars. Each one is either plainly true or plainly false, and the
 * server decides which in my_profile_stats() so the list cannot be talked
 * into lighting up.
 */
export interface Badge {
  id: string;
  name: string;
  how: string;
}

export const BADGES: Badge[] = [
  { id: "first_room", name: "First room", how: "Host a draft" },
  { id: "ten_rooms", name: "Ten rooms", how: "Host ten drafts" },
  { id: "five_drafts", name: "Regular", how: "Play five drafts" },
  { id: "deck_builder", name: "Deck builder", how: "Save a category to your profile" },
  { id: "first_win", name: "Called it", how: "Win a draft on the post-game vote" },
  { id: "judged", name: "Put to the vote", how: "Have an audience judge one of your drafts" },
];
