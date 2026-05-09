/**
 * MatchmakingService
 *
 * Handles matchmaking queue, player matching, and room lifecycle for matchmaking mode.
 * Extracted from roomController.matchmake, leaveQueue, queueStatus, and related cleanup.
 */

const ROOM_TTL_MS = 10 * 60 * 1000; // rooms expire after 10 minutes
const QUEUE_STALE_MS = 60 * 1000;   // queue entries older than this are evicted

class MatchmakingService {
  /**
   * @param {object} rooms - The global rooms object (in-memory store)
   * @param {function} isPenalizedFn - (userId) => Promise<boolean> from gameController.isMatchmakingPenalized
   */
  constructor(rooms, isPenalizedFn) {
    this.rooms = rooms;
    this.isPenalized = isPenalizedFn;
    this.queue = []; // { user_id, display_name, queued_at }

    // Evict stale queue entries every 30 seconds
    setInterval(() => this._evictStaleQueueEntries(), 30 * 1000);
  }

  /**
   * Clean up old matchmaking rooms for a user before they join queue.
   * @param {number} userId
   * @private
   */
  _cleanupStaleRoomsForUser(userId) {
    for (const code in this.rooms) {
      const r = this.rooms[code];
      if (!r.matchmaking) continue;
      if (r.host_id == userId || r.guest_id == userId) {
        console.log(`[Matchmaking] Cleaning up stale room ${code} (status=${r.status}) for user ${userId}`);
        delete this.rooms[code];
      }
    }
  }

  /**
   * Remove queue entries older than QUEUE_STALE_MS.
   * @private
   */
  _evictStaleQueueEntries() {
    const now = Date.now();
    for (let i = this.queue.length - 1; i >= 0; i--) {
      if (now - this.queue[i].queued_at > QUEUE_STALE_MS) {
        console.log(`[Matchmaking] Evicting stale queue entry for user ${this.queue[i].user_id}`);
        this.queue.splice(i, 1);
      }
    }
  }

  /**
   * Create a new matchmaking room and return its code.
   * @private
   */
  _createMatchmakingRoom(hostId, hostName, guestId, guestName) {
    const code = Math.random().toString(36).substring(2, 8).toUpperCase();
    // Clean up any old rooms for either player
    for (const c in this.rooms) {
      if (this.rooms[c].host_id === hostId || this.rooms[c].host_id === guestId) delete this.rooms[c];
    }
    this.rooms[code] = _makeMatchmakingRoom(code, hostId, hostName, guestId, guestName);
    console.log(`[Matchmaking] Matched ${hostId} (host) vs ${guestId} (guest) → room ${code}`);
    return code;
  }

  /**
   * Player joins the matchmaking queue.
   * @param {number} userId
   * @param {string} displayName
   * @returns {Promise<{ ok: boolean, role: 'waiting'|'guest', room?: object }>}
   */
  async join(userId, displayName) {
    // Check penalty server-side
    if (await this.isPenalized(userId)) {
      return { ok: false, status: 429, message: 'Matchmaking penalty active. Please wait before queuing again.' };
    }

    // Clean up stale rooms for this user
    this._cleanupStaleRoomsForUser(userId);

    // Remove any existing queue entry for this user
    const existingIdx = this.queue.findIndex(e => e.user_id == userId);
    if (existingIdx !== -1) this.queue.splice(existingIdx, 1);

    // Check for opponent
    const opponent = this.queue.find(e => e.user_id != userId);
    if (opponent) {
      // Match found
      this.queue.splice(this.queue.indexOf(opponent), 1);
      const code = this._createMatchmakingRoom(opponent.user_id, opponent.display_name, userId, displayName || 'Player');
      return { ok: true, role: 'guest', room: roomSnapshot(this.rooms[code]) };
    }

    // No opponent yet - add to queue
    this.queue.push({ user_id: userId, display_name: displayName || 'Player', queued_at: Date.now() });
    console.log(`[Matchmaking] ${userId} added to queue (queue size: ${this.queue.length})`);
    return { ok: true, role: 'waiting' };
  }

  /**
   * Player leaves the matchmaking queue.
   * @param {number} userId
   * @returns {void}
   */
  leave(userId) {
    const idx = this.queue.findIndex(e => e.user_id == userId);
    if (idx !== -1) {
      this.queue.splice(idx, 1);
      console.log(`[Matchmaking] ${userId} left queue (queue size: ${this.queue.length})`);
    }
  }

  /**
   * Check if a player has been matched.
   * Used for polling from client.
   * @param {number} userId
   * @returns {{ matched: boolean, in_queue: boolean, role?: 'host'|'guest', room?: object }}
   */
  getStatus(userId) {
    // Check if matched in any matchmaking room
    for (const code in this.rooms) {
      const room = this.rooms[code];
      if (!room.matchmaking) continue;
      if (room.status !== 'lobby') continue;
      if (room.host_id == userId || room.guest_id == userId) {
        _touchRoomPresence(room, userId);
        const role = room.host_id == userId ? 'host' : 'guest';
        return { ok: true, matched: true, in_queue: false, role, room: roomSnapshot(room) };
      }
    }
    // Still in queue?
    const inQueue = this.queue.some(e => e.user_id == userId);
    return { ok: true, matched: false, in_queue: inQueue };
  }

  /**
   * Get current queue size (for debugging/metrics)
   * @returns {number}
   */
  getQueueSize() {
    return this.queue.length;
  }
}

// Helper: creates the initial matchmaking room object.
// Kept private but accessible to service (module-level function)
function _makeMatchmakingRoom(code, hostId, hostName, guestId, guestName) {
  return {
    code,
    seq: 0,
    matchmaking: true,
    matchmaking_deadline_at: Date.now() + 60000,
    host_id: hostId,
    host_name: hostName,
    host_character: null,
    host_skills: [],
    host_passive: "",
    guest_id: guestId,
    guest_name: guestName,
    guest_character: null,
    guest_skills: [],
    guest_passive: "",
    status: 'lobby',
    host_progress: 0.0,
    guest_progress: 0.0,
    host_typos: 0,
    guest_typos: 0,
    host_mana: 2,
    guest_mana: 2,
    host_typing_start: 0,
    guest_typing_start: 0,
    host_mutations: [],
    host_skill: "",
    host_skill_picked: false,
    guest_mutations: [],
    guest_skill: "",
    guest_skill_picked: false,
    phase: 'lobby',
    phase_started_at: 0,
    typing_started_at: 0,
    first_finish_at: 0,
    first_finish_by: null,
    round_id: 0,
    host_hp: 0,
    guest_hp: 0,
    host_streak: 0,
    guest_streak: 0,
    finished_at: 0,
    history_saved: false,
    host_last_seen_at: Date.now(),
    guest_last_seen_at: Date.now(),
    forfeit: null,
    disconnect: null,
    created_at: Date.now(),
    last_activity_at: Date.now()
  };
}

// roomSnapshot helper used by service
function roomSnapshot(room) {
  return { ...room, server_now: Date.now() };
}

// Presence touch helper used by getStatus
function _touchRoomPresence(room, actorId) {
  const now = Date.now();
  room.last_activity_at = now;
  if (room.host_id == actorId) {
    room.host_last_seen_at = now;
    if (room.disconnect) room.disconnect.host_suspect_at = 0;
  } else if (room.guest_id == actorId) {
    room.guest_last_seen_at = now;
    if (room.disconnect) room.disconnect.guest_suspect_at = 0;
  }
}

module.exports = MatchmakingService;
