/**
 * RoomStore — in-memory room storage with TTL eviction and presence tracking.
 * Extracted from roomController.js to reduce controller size.
 */

// Presence thresholds
const ROOM_PRESENCE_SUSPECT_MS = 15000;
const ROOM_PRESENCE_FORFEIT_MS = 35000;
const ROOM_FORFEIT_DELETE_GRACE_MS = 30000;
const ROOM_IDLE_TTL_MS = 10 * 60 * 1000;

class RoomStore {
    constructor() {
        this.rooms = {};
        this._cleanupTimer = null;
    }

    /**
     * Start the cleanup interval (evict idle rooms, handle auto-forfeit).
     * Should be called once at server startup.
     * @param {function} autoForfeitHandler - Called with (room) to check/handle auto-forfeit
     */
    startCleanup(autoForfeitHandler, intervalMs = 60 * 1000) {
        if (this._cleanupTimer) return; // Prevent duplicate timers
        this._cleanupTimer = setInterval(() => {
            const now = Date.now();
            for (const code in this.rooms) {
                const room = this.rooms[code];
                if (autoForfeitHandler) autoForfeitHandler(room);
                const lastActivity = room.last_activity_at || room.created_at;
                const ttl = room.forfeit ? ROOM_FORFEIT_DELETE_GRACE_MS : ROOM_IDLE_TTL_MS;
                if (now - lastActivity > ttl) {
                    delete this.rooms[code];
                }
            }
        }, intervalMs);
    }

    /** Stop the cleanup interval (for tests/shutdown) */
    stopCleanup() {
        if (this._cleanupTimer) {
            clearInterval(this._cleanupTimer);
            this._cleanupTimer = null;
        }
    }

    /** Normalize room code to uppercase string */
    normalizeCode(code) {
        return String(code || '').toUpperCase();
    }

    /** Get room by code */
    get(code) {
        return this.rooms[this.normalizeCode(code)];
    }

    /** Set room by code */
    set(code, room) {
        this.rooms[this.normalizeCode(code)] = room;
    }

    /** Delete room by code */
    delete(code) {
        delete this.rooms[this.normalizeCode(code)];
    }

    /** Check if room exists */
    has(code) {
        return this.normalizeCode(code) in this.rooms;
    }

    /** Get all room codes */
    codes() {
        return Object.keys(this.rooms);
    }

    /** Get all rooms as array */
    all() {
        return Object.values(this.rooms);
    }

    /** Create a new room with default structure */
    createRoom(code, hostId, hostName) {
        const now = Date.now();
        const normalizedCode = this.normalizeCode(code);
        this.rooms[normalizedCode] = {
            code: normalizedCode,
            seq: 0,
            matchmaking: false,
            matchmaking_deadline_at: 0,
            host_id: hostId,
            host_name: hostName || 'Player',
            host_character: null,
            host_skills: [],
            host_passive: "",
            guest_id: null,
            guest_name: null,
            guest_character: null,
            guest_skills: [],
            guest_passive: "",
            status: 'lobby',
            host_progress: 0.0,
            host_typos: 0,
            host_mutations: [],
            host_skill: "",
            host_skill_picked: false,
            guest_progress: 0.0,
            guest_typos: 0,
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
            host_last_seen_at: now,
            guest_last_seen_at: 0,
            host_wants_rematch: false,
            guest_wants_rematch: false,
            forfeit: null,
            disconnect: null,
            created_at: now,
            last_activity_at: now
        };
        return this.rooms[normalizedCode];
    }

    /** Update presence timestamp for a player */
    touchPresence(room, actorId) {
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

    /** Check for auto-forfeit conditions and return forfeit info if triggered */
    checkAutoForfeit(room) {
        if (!room || room.status !== 'started') return null;
        if (room.forfeit) return null;
        if (!room.host_id || !room.guest_id) return null;

        const now = Date.now();
        const hostSeen = room.host_last_seen_at || room.created_at || 0;
        const guestSeen = room.guest_last_seen_at || room.created_at || 0;

        const hostSuspect = (now - hostSeen) > ROOM_PRESENCE_SUSPECT_MS;
        const guestSuspect = (now - guestSeen) > ROOM_PRESENCE_SUSPECT_MS;
        if (!hostSuspect && !guestSuspect) return null;

        if (!room.disconnect) {
            room.disconnect = { host_suspect_at: 0, guest_suspect_at: 0 };
        }
        if (hostSuspect && !room.disconnect.host_suspect_at) room.disconnect.host_suspect_at = now;
        if (guestSuspect && !room.disconnect.guest_suspect_at) room.disconnect.guest_suspect_at = now;

        const hostForfeit = hostSuspect && (now - hostSeen) > ROOM_PRESENCE_FORFEIT_MS;
        const guestForfeit = guestSuspect && (now - guestSeen) > ROOM_PRESENCE_FORFEIT_MS;
        if (!hostForfeit && !guestForfeit) return null;

        let by = null;
        if (hostForfeit && !guestForfeit) by = 'host';
        else if (guestForfeit && !hostForfeit) by = 'guest';

        return { by, reason: 'disconnect_timeout', now };
    }

    /** Delete all rooms hosted by a user */
    deleteByHost(hostId) {
        for (const code in this.rooms) {
            if (this.rooms[code].host_id === hostId) {
                delete this.rooms[code];
            }
        }
    }

    /** Create a snapshot with server timestamp */
    snapshot(room) {
        return { ...room, server_now: Date.now() };
    }
}

module.exports = RoomStore;
