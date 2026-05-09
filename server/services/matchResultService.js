/**
 * MatchResultService
 *
 * Handles match result derivation, persistence, and leaderboard updates.
 * Extracted from roomController._derivePlayerStats, _persistMatchResults, _upsertLeaderboardRow
 */

const NOMINAL_SENTENCE_CHARS = 100;

class MatchResultService {
  /**
   * @param {object} db - SQLite database instance
   * @param {object} characterData - Character definitions (from characters.json)
   */
  constructor(db, characterData) {
    this.db = db;
    this.characterData = characterData;
  }

  /**
   * Derive player statistics from room state.
   * @param {object} room - Room snapshot
   * @param {string} role - 'host' or 'guest'
   * @param {number} endedAt - Unix timestamp when match ended
   * @returns {{ typos: number, wpm: number, accuracy: number }}
   */
  derivePlayerStats(room, role, endedAt) {
    const progress = Math.min(1, Math.max(0, Number(room[`${role}_progress`]) || 0));
    const typos = Math.min(500, Math.max(0, Math.floor(Number(room[`${role}_typos`]) || 0)));
    const startedAt =
      Number(room[`${role}_typing_start`]) ||
      Number(room.typing_started_at) ||
      Number(room.phase_started_at) ||
      Number(room.started_at) ||
      endedAt;
    const finishedAt =
      progress >= 0.999 && room.first_finish_by === role && Number(room.first_finish_at) > 0
        ? Number(room.first_finish_at)
        : endedAt;
    const elapsedMs = Math.max(1000, finishedAt - startedAt);
    const typedChars = progress * NOMINAL_SENTENCE_CHARS;
    const elapsedMin = elapsedMs / 60000;
    const wpm = Math.min(250, Math.max(0, (typedChars / 5) / elapsedMin));
    const totalInput = typedChars + typos;
    const accuracy = totalInput > 0 ? (typedChars / totalInput) * 100 : 100;

    return {
      typos,
      wpm: Number(wpm.toFixed(1)),
      accuracy: Number(Math.min(100, Math.max(0, accuracy)).toFixed(1)),
    };
  }

  /**
   * Persist match results to database (history + leaderboard).
   * Idempotent - checks room.history_saved flag.
   * @param {object} room - Room snapshot
   * @param {number} [endedAt=Date.now()] - Match end timestamp
   */
  persistMatchResults(room, endedAt = Date.now()) {
    if (!room || room.history_saved) return;
    if (!room.host_id || !room.guest_id) return;

    let winner = '';
    if (room.forfeit && typeof room.forfeit.winner === 'string') {
      winner = room.forfeit.winner;
    } else {
      const hostHp = Number(room.host_hp);
      const guestHp = Number(room.guest_hp);
      const hostDead = Number.isFinite(hostHp) && hostHp <= 0;
      const guestDead = Number.isFinite(guestHp) && guestHp <= 0;
      if (hostDead && guestDead) winner = 'guest';
      else if (guestDead) winner = 'host';
      else if (hostDead) winner = 'guest';
    }
    if (winner !== 'host' && winner !== 'guest') return;

    room.history_saved = true;
    room.finished_at = endedAt;

    const matchType = room.matchmaking ? 'online' : 'custom';
    const hostName = room.host_name || 'Player';
    const guestName = room.guest_name || 'Player';
    const hostStats = this.derivePlayerStats(room, 'host', endedAt);
    const guestStats = this.derivePlayerStats(room, 'guest', endedAt);

    const rows = [
      { userId: room.host_id, username: hostName, won: winner === 'host', stats: hostStats },
      { userId: room.guest_id, username: guestName, won: winner === 'guest', stats: guestStats },
    ];

    for (const row of rows) {
      this.db.run(
        'INSERT INTO match_history (user_id, username, match_type, wpm, accuracy, typos, won) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [row.userId, row.username, matchType, row.stats.wpm, row.stats.accuracy, row.stats.typos, row.won ? 1 : 0],
        (err) => {
          if (err) {
            console.error('[MatchResult] Failed to save match history:', err.message);
            return;
          }
          this._upsertLeaderboardRow(row.userId, row.username, row.won, row.stats);
        }
      );
    }
  }

  /**
   * Update or insert leaderboard row for a winner.
   * @private
   */
  _upsertLeaderboardRow(userId, username, won, stats) {
    if (!won) return;
    this.db.get('SELECT id FROM leaderboard WHERE user_id = ?', [userId], (err, row) => {
      if (err) {
        console.error('[MatchResult] Leaderboard lookup failed:', err.message);
        return;
      }
      if (row) {
        this.db.run(
          'UPDATE leaderboard SET wins = wins + 1, wpm = ?, accuracy = ?, username = ?, date = CURRENT_TIMESTAMP WHERE user_id = ?',
          [stats.wpm, stats.accuracy, username, userId],
          (updateErr) => {
            if (updateErr) console.error('[MatchResult] Leaderboard update failed:', updateErr.message);
          }
        );
        return;
      }
      this.db.run(
        'INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, 1, ?, ?)',
        [userId, username, stats.wpm, stats.accuracy],
        (insertErr) => {
          if (insertErr) console.error('[MatchResult] Leaderboard insert failed:', insertErr.message);
        }
      );
    });
  }
}

module.exports = MatchResultService;
