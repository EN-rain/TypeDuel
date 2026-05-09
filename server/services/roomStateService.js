/**
 * RoomStateService
 *
 * Manages room state transitions: skill_select, typing, forfeit, HP-based finish.
 * Extracted from roomController state mutation functions.
 */

class RoomStateService {
  /**
   * @param {MatchResultService} matchResultService
   */
  constructor(matchResultService) {
    this.matchResultService = matchResultService;
  }

  /**
   * Transition room to skill_select phase (new round).
   * @param {object} room
   * @param {number} [nowMs=Date.now()]
   * @param {number} [roundId=null]
   */
  enterSkillSelectPhase(room, nowMs = Date.now(), roundId = null) {
    room.phase = 'skill_select';
    room.phase_started_at = now;
    room.host_skill = '';
    room.guest_skill = '';
    room.host_skill_picked = false;
    room.guest_skill_picked = false;
    if (Number(roundId) > 0) {
      room.round_id = Number(roundId);
    }
  }

  /**
   * Transition room to typing phase.
   * @param {object} room
   * @param {number} [nowMs=Date.now()]
   */
  enterTypingPhase(room, nowMs = Date.now()) {
    const now = nowMs || Date.now();
    room.phase = 'typing';
    room.phase_started_at = now;
    if (room.round_id <= 1) {
      room.typing_started_at = now + 3000;
    } else {
      room.typing_started_at = now;
    }
    room.first_finish_at = 0;
    room.first_finish_by = null;
    room.host_progress = 0.0;
    room.guest_progress = 0.0;
    room.host_typos = 0;
    room.guest_typos = 0;
    room.host_typing_start = 0;
    room.guest_typing_start = 0;
    room.host_mutations = [];
    room.guest_mutations = [];
    // Mana is reset by server when phase starts (handled in roomController.startRoomGame for initial, and maybe here for subsequent)
    // Actually initial mana set in startRoomGame; for rematches, it's reset in updateRematch.
    // We don't touch mana here - it's managed elsewhere.
  }

  /**
   * Finish room by forfeit (disconnect or mid-game leave).
   * Persists results and marks room finished.
   * @param {object} room
   * @param {'host'|'guest'} by - Who forfeited
   * @param {string} reason - 'leave' | 'disconnect_timeout'
   * @param {number} nowMs
   */
  finishRoomByForfeit(room, by, reason = 'leave', nowMs = Date.now()) {
    if (!room || room.status === 'finished') return;
    const winner = by === 'host' ? 'guest' : 'host';
    room.forfeit = { at: nowMs, by, winner, loser: by, reason };
    room.status = 'finished';
    room.phase = 'finished';
    room.finished_at = nowMs;
    room.seq = (room.seq || 0) + 1;
    room.last_activity_at = nowMs;
    this.matchResultService.persistMatchResults(room, nowMs);
  }

  /**
   * Check if HP deaths should end the match.
   * Called after HP sync.
   * @param {object} room
   * @param {number} [nowMs=Date.now()]
   * @returns {boolean} true if room was finished due to HP
   */
  finishRoomFromHp(room, nowMs = Date.now()) {
    if (!room || room.status === 'finished') return false;
    const hostHp = Number(room.host_hp);
    const guestHp = Number(room.guest_hp);
    const hostDead = Number.isFinite(hostHp) && hostHp <= 0;
    const guestDead = Number.isFinite(guestHp) && guestHp <= 0;
    if (!hostDead && !guestDead) return false;

    room.status = 'finished';
    room.phase = 'finished';
    room.finished_at = nowMs;
    room.seq = (room.seq || 0) + 1;
    room.last_activity_at = nowMs;
    this.matchResultService.persistMatchResults(room, nowMs);
    return true;
  }
}

module.exports = RoomStateService;
