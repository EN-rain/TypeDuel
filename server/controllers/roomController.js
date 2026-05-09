// In-memory room store
// rooms[code] = { code, host_id, host_name, guest_id, guest_name, created_at }
const rooms = {};
const db = require('../config/db');
const characterData = require('../data/characters.json');

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

    _finishRoomByForfeit(room, by, 'disconnect_timeout', now);
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

// allowed values for server-side selection validation
const VALID_CHARACTERS = new Set(['Riven', 'Zephon', 'Liora']);
const VALID_SKILLS     = new Set(['quickslash', 'whiplash', 'soulbreak']);
const VALID_PASSIVES   = new Set(['reversal', 'jumble', 'phantom', 'stutter', 'erosion']);
const VALID_PHASES     = new Set(['lobby', 'skill_select', 'typing', 'resolving', 'finished']);
const NOMINAL_SENTENCE_CHARS = 100;

function _characterHp(characterName) {
    const characters = Array.isArray(characterData.characters) ? characterData.characters : [];
    const character = characters.find(c => c.name === characterName);
    return character ? Number(character.hp) || 100 : 100;
}

function _upsertLeaderboardRow(userId, username, won, stats) {
    if (!won) return;
    db.get('SELECT id FROM leaderboard WHERE user_id = ?', [userId], (err, row) => {
        if (err) {
            console.error('[MatchResult] Leaderboard lookup failed:', err.message);
            return;
        }
        if (row) {
            db.run(
                'UPDATE leaderboard SET wins = wins + 1, wpm = ?, accuracy = ?, username = ?, date = CURRENT_TIMESTAMP WHERE user_id = ?',
                [stats.wpm, stats.accuracy, username, userId],
                (updateErr) => {
                    if (updateErr) console.error('[MatchResult] Leaderboard update failed:', updateErr.message);
                }
            );
            return;
        }
        db.run(
            'INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, 1, ?, ?)',
            [userId, username, stats.wpm, stats.accuracy],
            (insertErr) => {
                if (insertErr) console.error('[MatchResult] Leaderboard insert failed:', insertErr.message);
            }
        );
    });
}

function _derivePlayerStats(room, role, endedAt) {
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

function _persistMatchResults(room, endedAt = Date.now()) {
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
    const hostStats = _derivePlayerStats(room, 'host', endedAt);
    const guestStats = _derivePlayerStats(room, 'guest', endedAt);

    const rows = [
        {
            userId: room.host_id,
            username: hostName,
            won: winner === 'host',
            stats: hostStats,
        },
        {
            userId: room.guest_id,
            username: guestName,
            won: winner === 'guest',
            stats: guestStats,
        },
    ];

    for (const row of rows) {
        db.run(
            'INSERT INTO match_history (user_id, username, match_type, wpm, accuracy, typos, won) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [row.userId, row.username, matchType, row.stats.wpm, row.stats.accuracy, row.stats.typos, row.won ? 1 : 0],
            (err) => {
                if (err) {
                    console.error('[MatchResult] Failed to save match history:', err.message);
                    return;
                }
                _upsertLeaderboardRow(row.userId, row.username, row.won, row.stats);
            }
        );
    }
}

function _enterSkillSelectPhase(room, nowMs, roundId = null) {
    const now = nowMs || Date.now();
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

// import penalty helpers from gameController
const { isMatchmakingPenalized, setMatchmakingPenalty } = require('./gameController');

// use last_activity_at for TTL so long games are not evicted mid-match
const ROOM_IDLE_TTL_MS = 10 * 60 * 1000; // evict only if idle for 10 minutes

// â”€â”€ Matchmaking queue â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Simple in-memory queue. Entries: { user_id, display_name, queued_at }
// Players are removed when matched, when they cancel, or after 60s stale timeout.
const matchmakingQueue = [];
const QUEUE_STALE_MS = 60 * 1000;

function _enterTypingPhase(room, nowMs) {
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
}

function _finishRoomByForfeit(room, by, reason = 'leave', nowMs = Date.now()) {
    if (!room || room.status === 'finished') return;
    const winner = by === 'host' ? 'guest' : 'host';
    room.forfeit = { at: nowMs, by, winner, loser: by, reason };
    room.status = 'finished';
    room.phase = 'finished';
    room.finished_at = nowMs;
    room.seq = (room.seq || 0) + 1;
    room.last_activity_at = nowMs;
    _persistMatchResults(room, nowMs);
}

function _finishRoomFromHp(room, nowMs = Date.now()) {
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
    _persistMatchResults(room, nowMs);
    return true;
}

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
        matchmaking_deadline_at: Date.now() + 60000,
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
        host_skill_picked: false,
        guest_mutations: [],
        guest_skill:     "",
        guest_skill_picked: false,
        phase:           'lobby',
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,
        round_id:          0,
        host_hp:           0,
        guest_hp:          0,
        host_streak:       0,
        guest_streak:      0,
        finished_at:       0,
        history_saved:     false,
        host_last_seen_at: Date.now(),
        guest_last_seen_at: Date.now(),
        forfeit:           null,
        disconnect:        null,
        created_at:        Date.now(),
        last_activity_at:  Date.now()
    };
}

// POST /api/rooms/queue/leave â€” remove player from matchmaking queue
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

// GET /api/rooms/queue/status â€” poll for match result
const queueStatus = (req, res) => {
    const actorId = _actorId(req);
    // Check if this player has been matched into a room
    for (const code in rooms) {
        const room = rooms[code];
        if (!room.matchmaking) continue;
        if (room.status !== 'lobby') continue;
        // Both players must be present for a valid match
        if (!room.host_id || !room.guest_id) continue;
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
        host_skill_picked: false,
        guest_progress: 0.0,
        guest_typos:    0,
        guest_mutations:[],
        guest_skill:    "",
        guest_skill_picked: false,
        // Phase sync (authoritative timers)
        phase:          'lobby',      // lobby, skill_select, typing, resolving, finished
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,      // 'host' | 'guest'
        round_id:          0,
        host_hp:           0,
        guest_hp:          0,
        host_streak:       0,
        guest_streak:      0,
        finished_at:       0,
        history_saved:     false,
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
//   - Lobby (not yet started): room is deleted silently. No forfeit, no penalty â€” applies to
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
        // In-game forfeit â€” guest wins. Penalty (if any) is applied by the client only for
        // matchmaking mode; custom-room hosts are not penalized.
        _finishRoomByForfeit(room, 'host', 'leave', Date.now());
        return res.json({ ok: true, room: roomSnapshot(room) });
    }
    // Lobby: just delete the room. No forfeit, no penalty.
    delete rooms[code];
    return res.json({ ok: true });
};

// POST /api/rooms/:code/leave  (either player leaves the room)
// Behaviour by game mode:
//   - Lobby (not yet started):
//       Host leaving  â†’ room is deleted silently. No forfeit, no penalty.
//       Guest leaving â†’ guest slot is cleared; room stays alive for the host. No forfeit, no penalty.
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
            // In-game forfeit â€” guest wins.
            _finishRoomByForfeit(room, 'host', 'leave', Date.now());
            return res.json({ ok: true, room: roomSnapshot(room) });
        }
        // Lobby: host is leaving their own room â€” delete it silently. No forfeit, no penalty.
        delete rooms[code];
        return res.json({ ok: true });
    }

    if (room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }

    if (room.status === 'started') {
        // In-game forfeit â€” host wins.
        _finishRoomByForfeit(room, 'guest', 'leave', Date.now());
        return res.json({ ok: true, room: roomSnapshot(room) });
    }

    // Lobby: guest is leaving â€” clear their slot so the host can accept a new guest.
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

    // Always clean up any stale lobby rooms for this user before queuing.
    // This handles the case where the client quit without sending DELETE.
    for (const c in rooms) {
        const r = rooms[c];
        if (!r.matchmaking) continue;
        if (r.host_id == actorId || r.guest_id == actorId) {
            console.log(`[Matchmaking] Cleaning up stale room ${c} (status=${r.status}) for user ${actorId}`);
            delete rooms[c];
        }
    }

    // Remove any stale queue entry for this user first
    const existingIdx = matchmakingQueue.findIndex(e => e.user_id == actorId);
    if (existingIdx !== -1) matchmakingQueue.splice(existingIdx, 1);

    // Check if there's already someone waiting
    const opponent = matchmakingQueue.find(e => e.user_id != actorId);
    if (opponent) {
        // Match found â€” remove opponent from queue and create a room
        matchmakingQueue.splice(matchmakingQueue.indexOf(opponent), 1);

        const code = Math.random().toString(36).substring(2, 8).toUpperCase();
        // Clean up any old rooms for either player
        for (const c in rooms) {
            if (rooms[c].host_id === actorId || rooms[c].host_id === opponent.user_id) delete rooms[c];
        }
        rooms[code] = _makeMatchmakingRoom(code, opponent.user_id, opponent.display_name, actorId, display_name || 'Player');
        console.log(`[Matchmaking] Matched ${opponent.user_id} (host) vs ${actorId} (guest) â†’ room ${code}`);
        return res.json({ ok: true, role: 'guest', room: roomSnapshot(rooms[code]) });
    }

    // No opponent yet â€” add to queue and return waiting status
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
    // Idempotent start: if already started, return current room state instead of 409.
    // This avoids client-side race errors when duplicate start requests arrive close together.
    if (room.status === 'started') {
        return res.json({ ok: true, already_started: true, room: roomSnapshot(room) });
    }

    // Server-side readiness validation (donâ€™t rely only on client UI).
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
    room.finished_at = 0;
    room.history_saved = false;
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
    room.host_hp = _characterHp(room.host_character);
    room.guest_hp = _characterHp(room.guest_character);
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
    if (phase === 'skill_select') {
        _enterSkillSelectPhase(room, now, round_id);
    }
    if (phase === 'typing') {
        _enterTypingPhase(room, now);
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
        // Store chosen skill during skill_select and typing.
        // skill_select is needed for host fast-forward when both players have chosen.
        // Stale values are cleared on phase transitions in updatePhase().
        if (req.body.chosen_skill !== undefined && (room.phase === 'skill_select' || room.phase === 'typing')) {
            const chosen = String(req.body.chosen_skill || '');
            if (chosen !== '') {
                if (!VALID_SKILLS.has(chosen)) {
                    return res.status(400).json({ message: 'Invalid chosen_skill' });
                }
                if (!Array.isArray(room.host_skills) || !room.host_skills.includes(chosen)) {
                    return res.status(400).json({ message: 'chosen_skill is not in host loadout' });
                }
            }
            room.host_skill = chosen;
            room.host_skill_picked = true;
        }
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
        // Store chosen skill during skill_select and typing.
        // skill_select is needed for host fast-forward when both players have chosen.
        // Stale values are cleared on phase transitions in updatePhase().
        if (req.body.chosen_skill !== undefined && (room.phase === 'skill_select' || room.phase === 'typing')) {
            const chosen = String(req.body.chosen_skill || '');
            if (chosen !== '') {
                if (!VALID_SKILLS.has(chosen)) {
                    return res.status(400).json({ message: 'Invalid chosen_skill' });
                }
                if (!Array.isArray(room.guest_skills) || !room.guest_skills.includes(chosen)) {
                    return res.status(400).json({ message: 'chosen_skill is not in guest loadout' });
                }
            }
            room.guest_skill = chosen;
            room.guest_skill_picked = true;
        }
    } else {
        return res.status(403).json({ message: 'Not in this room' });
    }

    // Authoritative fast-forward: once both players choose a skill in skill_select,
    // transition immediately to typing on the server.
    let phaseTransitioned = false;
    if (room.phase === 'skill_select' && room.host_skill_picked && room.guest_skill_picked) {
        _enterTypingPhase(room, Date.now());
        phaseTransitioned = true;
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
    // Return the full room snapshot when a phase transition occurred so the client
    // can apply it immediately without waiting for the next poll cycle.
    if (phaseTransitioned) {
        return res.json({ ok: true, room: roomSnapshot(room) });
    }
    return res.json({ ok: true });
};

// PATCH /api/rooms/:code/hp
// Body: { user_id, host_hp, guest_hp, host_streak, guest_streak }
// Host is authoritative for HP and streak sync.
const updateHP = (req, res) => {
    const code = _normalizeCode(req.params.code);
    const { user_id, host_hp, guest_hp, host_streak, guest_streak } = req.body;
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
    // Persist streak state so GUEST can sync authoritative values from HOST
    if (host_streak !== undefined) room.host_streak = Number(host_streak) || 0;
    if (guest_streak !== undefined) room.guest_streak = Number(guest_streak) || 0;
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId); //presence: refresh idle timer / last seen
    _finishRoomFromHp(room, Date.now());
    if (process.env.LOG_ROOMS === 'true') {
        console.log(`[rooms] ${code} hp host=${room.host_hp} guest=${room.guest_hp} streaks=${room.host_streak}/${room.guest_streak}`);
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
        room.phase_started_at = 0;
        room.typing_started_at = 0;
        room.first_finish_at = 0;
        room.first_finish_by = null;
        room.round_id = 0;

        // Fresh 60s selection window for the rematch
        if (room.matchmaking) {
            room.matchmaking_deadline_at = Date.now() + 60000;
        }

        // Clear selections
        room.host_character = null;
        room.host_skills = [];
        room.host_passive = "";
        room.host_skill = "";
        room.host_skill_picked = false;
        room.host_progress = 0.0;
        room.host_typos = 0;
        room.host_mutations = [];
        room.host_hp = room.host_character ? _characterHp(room.host_character) : 0;
        room.host_streak = 0;

        room.guest_character = null;
        room.guest_skills = [];
        room.guest_passive = "";
        room.guest_skill = "";
        room.guest_skill_picked = false;
        room.guest_progress = 0.0;
        room.guest_typos = 0;
        room.guest_mutations = [];
        room.guest_hp = room.guest_character ? _characterHp(room.guest_character) : 0;
        room.guest_streak = 0;

        // Reset rematch flags
        room.host_wants_rematch = false;
        room.guest_wants_rematch = false;

        // Clear forfeit if any
        room.forfeit = null;
        room.disconnect = null;
        room.finished_at = 0;
        room.history_saved = false;
    }
    
    room.seq = (room.seq || 0) + 1;
    _touchRoomPresence(room, actorId);

    return res.json({ ok: true, rematch_ready: !!(room.host_wants_rematch && room.guest_wants_rematch) || room.status === 'lobby', room: roomSnapshot(room) });
};

module.exports = {
    createRoom, joinRoom, getRoomStatus, closeRoom, leaveRoom,
    matchmake, leaveQueue, queueStatus, listRooms,
    updateSelections, startRoomGame, updatePhase, updateProgress, updateHP, updateRematch,
    // Shared state for socket handler â€” same in-memory store, no duplication
    rooms,
    _enterTypingPhase,
    _enterSkillSelectPhase,
    _finishRoomByForfeit,
    _finishRoomFromHp,
    roomSnapshot,
};
