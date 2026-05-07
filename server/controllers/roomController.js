// In-memory room store
// rooms[code] = { code, host_id, host_name, guest_id, guest_name, created_at }
const rooms = {};

const ROOM_TTL_MS = 10 * 60 * 1000; // rooms expire after 10 minutes

// Realtime presence / disconnect handling
// Two-stage detection: mark a player as "suspected offline" first, then forfeit only if it persists.
// This reduces false-forfeits from transient stalls/background throttling.
const ROOM_PRESENCE_SUSPECT_MS = 15000;
const ROOM_PRESENCE_FORFEIT_MS = 35000;
const ROOM_FORFEIT_DELETE_GRACE_MS = 30000; // keep forfeited rooms briefly so clients can read the result

function _normalizeCode(code) {
    return String(code || '').toUpperCase();
}

function _actorId(req) {
    return req.user && req.user.id;
}

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

function _maybeAutoForfeitRoom(room) {
    if (!room || room.status !== 'started') return;
    if (room.forfeit) return;
    if (!room.host_id || !room.guest_id) return;

    const now = Date.now();
    // IMPORTANT: do not fall back to room.last_activity_at for per-player presence.
    // last_activity_at can be updated by the *other* player, which would mask a disconnect and
    // can incorrectly assign the forfeit/penalty to the wrong side.
    const hostSeen = room.host_last_seen_at || room.created_at || 0;
    const guestSeen = room.guest_last_seen_at || room.created_at || 0;

    const hostSuspect = (now - hostSeen) > ROOM_PRESENCE_SUSPECT_MS;
    const guestSuspect = (now - guestSeen) > ROOM_PRESENCE_SUSPECT_MS;
    if (!hostSuspect && !guestSuspect) return;

    if (!room.disconnect) {
        room.disconnect = { host_suspect_at: 0, guest_suspect_at: 0 };
    }
    if (hostSuspect && !room.disconnect.host_suspect_at) room.disconnect.host_suspect_at = now;
    if (guestSuspect && !room.disconnect.guest_suspect_at) room.disconnect.guest_suspect_at = now;

    const hostForfeit = hostSuspect && (now - hostSeen) > ROOM_PRESENCE_FORFEIT_MS;
    const guestForfeit = guestSuspect && (now - guestSeen) > ROOM_PRESENCE_FORFEIT_MS;
    if (!hostForfeit && !guestForfeit) return;

    let by = null;
    if (hostForfeit && !guestForfeit) by = 'host';
    else if (guestForfeit && !hostForfeit) by = 'guest';

    let winner = null;
    let loser = null;
    if (by === 'host') { winner = 'guest'; loser = 'host'; }
    else if (by === 'guest') { winner = 'host'; loser = 'guest'; }

    room.forfeit = { at: now, by, winner, loser, reason: 'disconnect_timeout' };
    room.status = 'finished';
    room.phase = 'finished';
    room.seq = (room.seq || 0) + 1;
    room.last_activity_at = now;
}

function _assertBodyUserMatchesActor(req, res) {
    const actorId = _actorId(req);
    // If the client sends user_id, ensure it matches the authenticated actor.
    // This prevents spoofing another user's actions with a valid token.
    if (req.body && req.body.user_id !== undefined && String(req.body.user_id) !== String(actorId)) {
        res.status(403).json({ message: 'user_id does not match authenticated user' });
        return false;
    }
    return true;
}

// Fix #6: allowed values for server-side selection validation
const VALID_CHARACTERS = new Set(['Riven', 'Zephon', 'Liora']);
const VALID_SKILLS     = new Set(['quickslash', 'whiplash', 'soulbreak']);
const VALID_PASSIVES   = new Set(['reversal', 'jumble', 'phantom', 'stutter', 'erosion']);
const VALID_PHASES     = new Set(['lobby', 'skill_select', 'typing', 'resolving', 'finished']);

// Fix #10 + Fix #14: import penalty helpers from gameController
const { isMatchmakingPenalized, setMatchmakingPenalty } = require('./gameController');

// Fix #14: use last_activity_at for TTL so long games are not evicted mid-match
const ROOM_IDLE_TTL_MS = 10 * 60 * 1000; // evict only if idle for 10 minutes

// ── Matchmaking queue ────────────────────────────────────────────────────────
// Simple in-memory queue. Entries: { user_id, display_name, queued_at }
// Players are removed when matched, when they cancel, or after 60s stale timeout.
const matchmakingQueue = [];
const QUEUE_STALE_MS = 60 * 1000;

// Evict stale queue entries every 30s
setInterval(() => {
    const now = Date.now();
    for (let i = matchmakingQueue.length - 1; i >= 0; i--) {
        if (now - matchmakingQueue[i].queued_at > QUEUE_STALE_MS) {
            console.log(`[Matchmaking] Evicting stale queue entry for user ${matchmakingQueue[i].user_id}`);
            matchmakingQueue.splice(i, 1);
        }
    }
}, 30 * 1000);

function _makeMatchmakingRoom(code, hostId, hostName, guestId, guestName) {
    return {
        code,
        seq:             0,
        matchmaking:     true,
        matchmaking_deadline_at: Date.now() + 15000,
        host_id:         hostId,
        host_name:       hostName,
        host_character:  null,
        host_skills:     [],
        host_passive:    "",
        guest_id:        guestId,
        guest_name:      guestName,
        guest_character: null,
        guest_skills:    [],
        guest_passive:   "",
        status:          'lobby',
        host_progress:   0.0,
        guest_progress:  0.0,
        host_typos:      0,
        guest_typos:     0,
        host_mana:       2,
        guest_mana:      2,
        host_typing_start: 0,
        guest_typing_start: 0,
        host_mutations:  [],
        host_skill:      "",
        guest_mutations: [],
        guest_skill:     "",
        phase:           'lobby',
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,
        round_id:          0,
        host_hp:           0,
        guest_hp:          0,
        host_last_seen_at: Date.now(),
        guest_last_seen_at: Date.now(),
        forfeit:           null,
        disconnect:        null,
        created_at:        Date.now(),
        last_activity_at:  Date.now()
    };
}

// POST /api/rooms/queue/leave — remove player from matchmaking queue
const leaveQueue = (req, res) => {
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    const idx = matchmakingQueue.findIndex(e => e.user_id == actorId);
    if (idx !== -1) {
        matchmakingQueue.splice(idx, 1);
        console.log(`[Matchmaking] ${actorId} left queue (queue size: ${matchmakingQueue.length})`);
    }
    return res.json({ ok: true });
};

// GET /api/rooms/queue/status — poll for match result
const queueStatus = (req, res) => {
    const actorId = _actorId(req);
    // Check if this player has been matched into a room
    for (const code in rooms) {
        const room = rooms[code];
        if (!room.matchmaking) continue;
        if (room.status !== 'lobby') continue;
        if (room.host_id == actorId || room.guest_id == actorId) {
            _touchRoomPresence(room, actorId);
            const role = room.host_id == actorId ? 'host' : 'guest';
            return res.json({ ok: true, matched: true, role, room: roomSnapshot(room) });
        }
    }
    // Still in queue?
    const inQueue = matchmakingQueue.some(e => e.user_id == actorId);
    return res.json({ ok: true, matched: false, in_queue: inQueue });
};

// Cleanup old rooms every minute
setInterval(() => {
    const now = Date.now();
    for (const code in rooms) {
        const room = rooms[code];
        _maybeAutoForfeitRoom(room);
        const lastActivity = room.last_activity_at || room.created_at;
        const ttl = room.forfeit ? ROOM_FORFEIT_DELETE_GRACE_MS : ROOM_IDLE_TTL_MS;
        if (now - lastActivity > ttl) {
            delete rooms[code];
        }
    }
}, 60 * 1000);

// POST /api/rooms/create
// Body: { user_id, display_name, code }
const createRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    const normalizedCode = _normalizeCode(code);
    // Clean up any existing room hosted by this user
    for (const c in rooms) {
        if (rooms[c].host_id === actorId) delete rooms[c];
    }
    rooms[normalizedCode] = {
        code: normalizedCode,
        seq:            0,
        matchmaking:    false,
        matchmaking_deadline_at: 0,
        host_id:        actorId,
        host_name:      display_name || 'Player',
        host_character: null,
        host_skills:    [],
        host_passive:   "",
        guest_id:       null,
        guest_name:     null,
        guest_character: null,
        guest_skills:   [],
        guest_passive:  "",
        status:         'lobby',
        host_progress:  0.0,
        host_typos:     0,
        host_mutations: [],
        host_skill:     "",
        guest_progress: 0.0,
        guest_typos:    0,
        guest_mutations:[],
        guest_skill:    "",
        // Phase sync (authoritative timers)
        phase:          'lobby',      // lobby, skill_select, typing, resolving, finished
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,      // 'host' | 'guest'
        round_id:          0,
        host_hp:           0,
        guest_hp:          0,
        host_last_seen_at: Date.now(),
        guest_last_seen_at: 0,
        // Rematch tracking
        host_wants_rematch: false,
        guest_wants_rematch: false,
        forfeit:        null,
        disconnect:     null,
        created_at:     Date.now(),
        last_activity_at: Date.now()
    };
    return res.json({ ok: true, code: normalizedCode });
};

// POST /api/rooms/join
// Body: { user_id, display_name, code }
const joinRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    const room = rooms[_normalizeCode(code)];
    if (!room) {
        return res.status(404).json({ message: 'Room not found' });
    }
    if (room.host_id == actorId) {   // loose == handles string/int mismatch
        return res.status(403).json({ message: 'Cannot join your own room' });
    }
    if (room.guest_id && room.guest_id != actorId) {
        return res.status(409).json({ message: 'Room is full' });
    }
    room.guest_id      = actorId;
    room.guest_name    = display_name || 'Player';
    room.guest_character = null;
    room.guest_skills  = [];
    room.guest_passive = "";
    room.guest_mana    = 2;  // Initialize guest mana
    room.guest_typing_start = 0;  // Initialize guest typing start time
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId);
    return res.json({ ok: true, room });
};

const roomSnapshot = (room) => ({
    ...room,
    server_now: Date.now()
});

// GET /api/rooms/:code
const getRoomStatus = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = _actorId(req);
    if (room.host_id != actorId && room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }
    _maybeAutoForfeitRoom(room);
    _touchRoomPresence(room, actorId);
    return res.json(roomSnapshot(room));
};

// DELETE /api/rooms/:code  (host closes the room)
// Behaviour by game mode:
//   - Lobby (not yet started): room is deleted silently. No forfeit, no penalty — applies to
//     both custom rooms and matchmaking lobbies.
//   - Started (in-game): recorded as a host forfeit so the guest sees the result. The
//     matchmaking penalty is applied client-side only when GameManager.is_matchmaking is true;
//     custom-room players are never penalized.
const closeRoom = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = _actorId(req);
    if (room.host_id != actorId) {
        return res.status(403).json({ message: 'Only host may close the room' });
    }
    if (room.status === 'started') {
        // In-game forfeit — guest wins. Penalty (if any) is applied by the client only for
        // matchmaking mode; custom-room hosts are not penalized.
        room.forfeit = { at: Date.now(), by: 'host', winner: 'guest', loser: 'host', reason: 'leave' };
        room.status = 'finished';
        room.phase = 'finished';
        room.seq = (room.seq || 0) + 1;
        room.last_activity_at = Date.now();
        return res.json({ ok: true, room: roomSnapshot(room) });
    }
    // Lobby: just delete the room. No forfeit, no penalty.
    delete rooms[code];
    return res.json({ ok: true });
};

// POST /api/rooms/:code/leave  (either player leaves the room)
// Behaviour by game mode:
//   - Lobby (not yet started):
//       Host leaving  → room is deleted silently. No forfeit, no penalty.
//       Guest leaving → guest slot is cleared; room stays alive for the host. No forfeit, no penalty.
//       This applies to BOTH custom rooms and matchmaking lobbies.
//   - Started (in-game): recorded as a forfeit so the remaining player sees the result.
//       The matchmaking penalty is applied client-side only when GameManager.is_matchmaking is
//       true; custom-room players are never penalized.
const leaveRoom = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = _actorId(req);

    if (room.host_id == actorId) {
        if (room.status === 'started') {
            // In-game forfeit — guest wins.
            room.forfeit = { at: Date.now(), by: 'host', winner: 'guest', loser: 'host', reason: 'leave' };
            room.status = 'finished';
            room.phase = 'finished';
            room.seq = (room.seq || 0) + 1;
            room.last_activity_at = Date.now();
            return res.json({ ok: true, room: roomSnapshot(room) });
        }
        // Lobby: host is leaving their own room — delete it silently. No forfeit, no penalty.
        delete rooms[code];
        return res.json({ ok: true });
    }

    if (room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }

    if (room.status === 'started') {
        // In-game forfeit — host wins.
        room.forfeit = { at: Date.now(), by: 'guest', winner: 'host', loser: 'guest', reason: 'leave' };
        room.status = 'finished';
        room.phase = 'finished';
        room.seq = (room.seq || 0) + 1;
        room.last_activity_at = Date.now();
        return res.json({ ok: true, room: roomSnapshot(room) });
    }

    // Lobby: guest is leaving — clear their slot so the host can accept a new guest.
    // Room stays alive. No forfeit, no penalty.

    room.guest_id = null;
    room.guest_name = null;
    room.guest_character = null;
    room.guest_skills = [];
    room.guest_passive = "";
    room.guest_progress = 0.0;
    room.guest_typos = 0;
    room.guest_mana = 2;  // Reset guest mana
    room.guest_typing_start = 0;  // Reset guest typing start
    room.guest_mutations = [];
    room.guest_skill = "";
    if (room.matchmaking) {
        room.matchmaking_deadline_at = 0;
    }
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId);
    return res.json({ ok: true, room: roomSnapshot(room) });
};

const matchmake = async (req, res) => {
    const { user_id, display_name } = req.body;
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    if (!user_id) return res.status(400).json({ message: 'user_id required' });

    // Fix #10: enforce server-side matchmaking penalty
    const penalized = await isMatchmakingPenalized(actorId);
    if (penalized) {
        return res.status(429).json({ message: 'Matchmaking penalty active. Please wait before queuing again.' });
    }

    // ── Queue-based matchmaking ──────────────────────────────────────────
    // Remove any stale queue entry for this user first
    const existingIdx = matchmakingQueue.findIndex(e => e.user_id == actorId);
    if (existingIdx !== -1) matchmakingQueue.splice(existingIdx, 1);

    // Check if there's already someone waiting
    const opponent = matchmakingQueue.find(e => e.user_id != actorId);
    if (opponent) {
        // Match found — remove opponent from queue and create a room
        matchmakingQueue.splice(matchmakingQueue.indexOf(opponent), 1);

        const code = Math.random().toString(36).substring(2, 8).toUpperCase();
        // Clean up any old rooms for either player
        for (const c in rooms) {
            if (rooms[c].host_id === actorId || rooms[c].host_id === opponent.user_id) delete rooms[c];
        }
        rooms[code] = _makeMatchmakingRoom(code, opponent.user_id, opponent.display_name, actorId, display_name || 'Player');
        console.log(`[Matchmaking] Matched ${opponent.user_id} (host) vs ${actorId} (guest) → room ${code}`);
        return res.json({ ok: true, role: 'guest', room: roomSnapshot(rooms[code]) });
    }

    // No opponent yet — add to queue and return waiting status
    matchmakingQueue.push({ user_id: actorId, display_name: display_name || 'Player', queued_at: Date.now() });
    console.log(`[Matchmaking] ${actorId} added to queue (queue size: ${matchmakingQueue.length})`);
    return res.json({ ok: true, role: 'waiting' });
};

// GET /api/rooms  (debug: list all active rooms)
const listRooms = (req, res) => {
    res.json(Object.values(rooms));
};

// PATCH /api/rooms/:code/select
// Body: { user_id, character, skills }
const updateSelections = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const { user_id, character, skills, passive } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);

    // Fix #6: validate character, skills, and passive against allowed values
    if (character !== undefined && !VALID_CHARACTERS.has(character)) {
        return res.status(400).json({ message: 'Invalid character' });
    }
    if (skills !== undefined) {
        if (!Array.isArray(skills) || skills.length > 2) {
            return res.status(400).json({ message: 'skills must be an array of at most 2 entries' });
        }
        for (const s of skills) {
            if (!VALID_SKILLS.has(s)) {
                return res.status(400).json({ message: `Invalid skill: ${s}` });
            }
        }
        const unique = new Set(skills);
        if (unique.size !== skills.length) {
            return res.status(400).json({ message: 'Duplicate skills are not allowed' });
        }
    }
    if (passive !== undefined && passive !== '' && !VALID_PASSIVES.has(passive)) {
        return res.status(400).json({ message: 'Invalid passive' });
    }

    if (room.host_id == actorId) {
        if (character !== undefined) room.host_character = character;
        if (skills !== undefined)    room.host_skills    = skills;
        if (passive !== undefined)   room.host_passive   = passive;
    } else if (room.guest_id == actorId) {
        if (character !== undefined) room.guest_character = character;
        if (skills !== undefined)    room.guest_skills    = skills;
        if (passive !== undefined)   room.guest_passive   = passive;
    } else {
        return res.status(403).json({ message: 'Not in this room' });
    }
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId); // Fix #14 + presence: refresh idle timer / last seen
    return res.json({ ok: true });
};

// POST /api/rooms/:code/start
const startRoomGame = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = _actorId(req);
    if (room.host_id != actorId) {
        return res.status(403).json({ message: 'Only host may start the game' });
    }
    if (!room.guest_id) {
        return res.status(409).json({ message: 'Cannot start without guest' });
    }
    if (room.status === 'started') {
        return res.status(409).json({ message: 'Room already started' });
    }

    // Server-side readiness validation (don’t rely only on client UI).
    const hostReady =
        !!room.host_character &&
        Array.isArray(room.host_skills) && room.host_skills.length >= 2 &&
        typeof room.host_passive === 'string' && room.host_passive !== '';
    const guestReady =
        !!room.guest_character &&
        Array.isArray(room.guest_skills) && room.guest_skills.length >= 2 &&
        typeof room.guest_passive === 'string' && room.guest_passive !== '';
    if (!hostReady || !guestReady) {
        return res.status(409).json({ message: 'Both players must pick character, 2 skills, and a passive before starting' });
    }

    room.status = 'started';
    room.started_at = Date.now();
    room.forfeit = null;
    room.disconnect = { host_suspect_at: 0, guest_suspect_at: 0 };

    // Initialize authoritative phase/timers for round 1
    room.round_id = 1;
    room.phase = 'skill_select';
    room.phase_started_at = room.started_at;
    room.typing_started_at = 0;
    room.first_finish_at = 0;
    room.first_finish_by = null;
    room.host_progress = 0.0;
    room.guest_progress = 0.0;
    room.host_typos = 0;
    room.guest_typos = 0;
    room.host_mana = 2;  // Reset mana for round 1
    room.guest_mana = 2;
    room.host_typing_start = 0;  // Reset typing start times
    room.guest_typing_start = 0;
    room.host_mutations = [];
    room.guest_mutations = [];
    // HP is set by host client via /hp once the game scene initializes.
    room.host_hp = room.host_hp || 0;
    room.guest_hp = room.guest_hp || 0;
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId);
    return res.json({ ok: true, room: roomSnapshot(room) });
};

// PATCH /api/rooms/:code/phase
// Body: { user_id, phase, round_id? }
// Host is authoritative for phase transitions.
const updatePhase = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const { user_id, phase, round_id } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!user_id || !phase) return res.status(400).json({ message: 'user_id and phase required' });
    if (!VALID_PHASES.has(phase)) return res.status(400).json({ message: 'Invalid phase' });
    if (room.status !== 'started') return res.status(409).json({ message: 'Room not started' });

    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);

    if (room.host_id != actorId) {
        return res.status(403).json({ message: 'Only host may change phase' });
    }

    const now = Date.now();
    room.phase = phase;
    room.phase_started_at = now;

    if (typeof round_id === 'number' && round_id > 0) {
        room.round_id = round_id;
    }
    if (phase === 'typing') {
        // Add a short ready countdown so the typing start isn't a surprise for the first round.
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
        room.host_typing_start = 0;  // Reset typing start times for new round
        room.guest_typing_start = 0;
        room.host_mutations = [];
        room.guest_mutations = [];
        room.host_skill = "";
        room.guest_skill = "";
    }

    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId); // Fix #14 + presence: refresh idle timer / last seen
    return res.json({ ok: true, room: roomSnapshot(room) });
};

// PATCH /api/rooms/:code/progress
const updateProgress = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const { user_id, progress, typos, send_mutation, mana } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    if (room.status !== 'started') return res.status(409).json({ message: 'Room not started' });

    const progressNum = (progress === undefined) ? undefined : Number(progress);
    const typosNum = (typos === undefined) ? undefined : Number(typos);
    const manaNum = (mana === undefined) ? undefined : Number(mana);

    // Fix #12: cap typos to a sane maximum to prevent damage manipulation
    const MAX_TYPOS = 500;

    if (room.host_id == actorId) {
        if (progressNum !== undefined && Number.isFinite(progressNum)) room.host_progress = Math.min(1.0, Math.max(0.0, progressNum));
        if (typosNum !== undefined && Number.isFinite(typosNum)) room.host_typos = Math.min(MAX_TYPOS, Math.max(0, Math.floor(typosNum)));
        // Accept mana updates in real-time so opponent can see mana increasing during typing
        if (manaNum !== undefined && Number.isFinite(manaNum)) {
            room.host_mana = Math.min(10, Math.max(0, Math.floor(manaNum)));
        }
        // Track when player actually starts typing (first progress update > 0)
        if (progressNum !== undefined && progressNum > 0 && room.host_typing_start === 0) {
            room.host_typing_start = Date.now();
        }
        if (send_mutation) room.guest_mutations.push(send_mutation);
        // Store chosen skill so opponent can see it in their stats label
        if (req.body.chosen_skill !== undefined) room.host_skill = String(req.body.chosen_skill || '');
    } else if (room.guest_id == actorId) {
        if (progressNum !== undefined && Number.isFinite(progressNum)) room.guest_progress = Math.min(1.0, Math.max(0.0, progressNum));
        if (typosNum !== undefined && Number.isFinite(typosNum)) room.guest_typos = Math.min(MAX_TYPOS, Math.max(0, Math.floor(typosNum)));
        // Accept mana updates in real-time so opponent can see mana increasing during typing
        if (manaNum !== undefined && Number.isFinite(manaNum)) {
            room.guest_mana = Math.min(10, Math.max(0, Math.floor(manaNum)));
        }
        // Track when player actually starts typing (first progress update > 0)
        if (progressNum !== undefined && progressNum > 0 && room.guest_typing_start === 0) {
            room.guest_typing_start = Date.now();
        }
        if (send_mutation) room.host_mutations.push(send_mutation);
        // Store chosen skill so opponent can see it in their stats label
        if (req.body.chosen_skill !== undefined) room.guest_skill = String(req.body.chosen_skill || '');
    } else {
        return res.status(403).json({ message: 'Not in this room' });
    }

    // Fix #7: first-finish is set only once and never overwritten.
    // We also record the exact timestamp so the second player can't race-overwrite it.
    if (!room.first_finish_at && progressNum !== undefined && Number.isFinite(progressNum) && progressNum >= 0.999) {
        room.first_finish_at = Date.now();
        room.first_finish_by = (room.host_id == actorId) ? 'host' : 'guest';
    }
    if (process.env.LOG_ROOMS === 'true' && progressNum !== undefined) {
        console.log(`[rooms] ${code} progress host=${room.host_progress} guest=${room.guest_progress} first_finish_at=${room.first_finish_at} by=${room.first_finish_by}`);
    }
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId); // + presence: refresh idle timer / last seen
    return res.json({ ok: true });
};

// PATCH /api/rooms/:code/hp
// Body: { user_id, host_hp, guest_hp }
// Host is authoritative for HP sync.
const updateHP = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const { user_id, host_hp, guest_hp } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!_assertBodyUserMatchesActor(req, res)) return;
    const actorId = _actorId(req);
    if (room.host_id != actorId) return res.status(403).json({ message: 'Only host may sync hp' });
    if (room.status !== 'started') return res.status(409).json({ message: 'Room not started' });

    const hostHpNum = Number(host_hp);
    const guestHpNum = Number(guest_hp);
    if (!Number.isFinite(hostHpNum) || !Number.isFinite(guestHpNum)) {
        return res.status(400).json({ message: 'host_hp and guest_hp must be numbers' });
    }

    room.host_hp = hostHpNum;
    room.guest_hp = guestHpNum;
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId); //presence: refresh idle timer / last seen
    if (process.env.LOG_ROOMS === 'true') {
        console.log(`[rooms] ${code} hp host=${room.host_hp} guest=${room.guest_hp}`);
    }
    return res.json({ ok: true, room: roomSnapshot(room) });
};

// PATCH /api/rooms/:code/rematch - Mark that a player wants to rematch
const updateRematch = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    
    const actorId = _actorId(req);
    if (room.host_id != actorId && room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }
    
    if (!_assertBodyUserMatchesActor(req, res)) return;
    
    const wantsRematch = req.body.wants_rematch === true;
    
    if (room.host_id == actorId) {
        room.host_wants_rematch = wantsRematch;
    } else if (room.guest_id == actorId) {
        room.guest_wants_rematch = wantsRematch;
    }
    
    // If both want rematch, reset the room to lobby state
    if (room.host_wants_rematch && room.guest_wants_rematch) {
        // Reset game state but keep players
        room.status = 'lobby';
        room.phase = 'lobby';
        room.phase_started_at = null;
        room.typing_started_at = null;
        room.first_finish_at = null;
        room.first_finish_by = null;
        room.round_id = 0;
        
        // Clear selections
        room.host_character = null;
        room.host_skills = [];
        room.host_passive = "";
        room.host_skill = "";
        room.host_progress = 0.0;
        room.host_typos = 0;
        room.host_mutations = [];
        room.host_hp = 100;
        
        room.guest_character = null;
        room.guest_skills = [];
        room.guest_passive = "";
        room.guest_skill = "";
        room.guest_progress = 0.0;
        room.guest_typos = 0;
        room.guest_mutations = [];
        room.guest_hp = 100;
        
        // Reset rematch flags
        room.host_wants_rematch = false;
        room.guest_wants_rematch = false;
        
        // Clear forfeit if any
        room.forfeit = null;
    }
    
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId);
    
    return res.json({ ok: true, room: roomSnapshot(room) });
};

module.exports = { createRoom, joinRoom, getRoomStatus, closeRoom, leaveRoom, matchmake, leaveQueue, queueStatus, listRooms, updateSelections, startRoomGame, updatePhase, updateProgress, updateHP, updateRematch };
