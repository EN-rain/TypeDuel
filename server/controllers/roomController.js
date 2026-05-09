// RoomStore — in-memory room storage with TTL eviction
const RoomStore = require('../store/RoomStore');
const roomStore = new RoomStore();

// Dependencies for services
const db = require('../config/db');
const characterData = require('../data/characters.json');
const { isMatchmakingPenalized } = require('./gameController');
const MatchResultService = require('../services/matchResultService');
const RoomStateService = require('../services/roomStateService');
const MatchmakingService = require('../services/matchmakingService');
const {
    validateSelections, validatePhase, validateChosenSkill,
    assertBodyUserMatchesActor, getActorId
} = require('../utils/validators');

// Service instances
const matchResultService = new MatchResultService(db, characterData);
const roomStateService = new RoomStateService(matchResultService);
const matchmakingService = new MatchmakingService(roomStore.rooms, isMatchmakingPenalized);

// Shorthand for room access
const rooms = roomStore.rooms;

// Helper: get character HP from data
function _characterHp(characterName) {
    const characters = Array.isArray(characterData.characters) ? characterData.characters : [];
    const character = characters.find(c => c.name === characterName);
    return character ? Number(character.hp) || 100 : 100;
}

// Phase transition helpers (delegate to RoomStateService)
function _enterSkillSelectPhase(room, nowMs, roundId = null) {
    roomStateService.enterSkillSelectPhase(room, nowMs, roundId);
}

function _enterTypingPhase(room, nowMs) {
    roomStateService.enterTypingPhase(room, nowMs);
}

function _finishRoomByForfeit(room, by, reason = 'leave', nowMs = Date.now()) {
    roomStateService.finishRoomByForfeit(room, by, reason, nowMs);
}

function _finishRoomFromHp(room, nowMs = Date.now()) {
    return roomStateService.finishRoomFromHp(room, nowMs);
}

// Start cleanup interval (handles auto-forfeit + TTL eviction)
// Exported so server.js can call it once at startup
function startCleanup() {
    roomStore.startCleanup((room) => {
        const forfeitInfo = roomStore.checkAutoForfeit(room);
        if (forfeitInfo) {
            _finishRoomByForfeit(room, forfeitInfo.by, forfeitInfo.reason, forfeitInfo.now);
        }
    });
}

// POST /api/rooms/queue/leave — remove player from matchmaking queue
const leaveQueue = (req, res) => {
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
    matchmakingService.leave(actorId);
    return res.json({ ok: true });
};

// GET /api/rooms/queue/status — poll for match result
const queueStatus = (req, res) => {
    const actorId = getActorId(req);
    const result = matchmakingService.getStatus(actorId);
    return res.json(result);
};

// POST /api/rooms/queue/join — enter matchmaking queue
const matchmake = async (req, res) => {
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
    const { user_id, display_name } = req.body;
    if (!user_id) return res.status(400).json({ message: 'user_id required' });

    const result = await matchmakingService.join(actorId, display_name);
    if (!result.ok) {
        return res.status(result.status || 400).json({ message: result.message });
    }
    if (result.role === 'waiting') {
        return res.json({ ok: true, role: 'waiting' });
    }
    return res.json({ ok: true, role: result.role, room: result.room });
};

// POST /api/rooms/create
// Body: { user_id, display_name, code }
const createRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    // Clean up any existing room hosted by this user
    roomStore.deleteByHost(actorId);
    // Create new room
    const room = roomStore.createRoom(code, actorId, display_name);
    return res.json({ ok: true, code: room.code });
};

// POST /api/rooms/join
// Body: { user_id, display_name, code }
const joinRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    const room = roomStore.get(code);
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
    roomStore.touchPresence(room, actorId);
    return res.json({ ok: true, room });
};

// GET /api/rooms/:code
const getRoomStatus = (req, res) => {
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = getActorId(req);
    if (room.host_id != actorId && room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }
    // Check for auto-forfeit
    const forfeitInfo = roomStore.checkAutoForfeit(room);
    if (forfeitInfo) _finishRoomByForfeit(room, forfeitInfo.by, forfeitInfo.reason, forfeitInfo.now);
    roomStore.touchPresence(room, actorId);
    return res.json(roomStore.snapshot(room));
};

// DELETE /api/rooms/:code  (host closes the room)
// Behaviour by game mode:
//   - Lobby (not yet started): room is deleted silently. No forfeit, no penalty — applies to
//     both custom rooms and matchmaking lobbies.
//   - Started (in-game): recorded as a host forfeit so the guest sees the result. The
//     matchmaking penalty is applied client-side only when GameManager.is_matchmaking is true;
//     custom-room players are never penalized.
const closeRoom = (req, res) => {
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = getActorId(req);
    if (room.host_id != actorId) {
        return res.status(403).json({ message: 'Only host may close the room' });
    }
    if (room.status === 'started') {
        // In-game forfeit — guest wins. Penalty (if any) is applied by the client only for
        // matchmaking mode; custom-room hosts are not penalized.
        _finishRoomByForfeit(room, 'host', 'leave', Date.now());
        return res.json({ ok: true, room: roomStore.snapshot(room) });
    }
    // Lobby: just delete the room. No forfeit, no penalty.
    roomStore.delete(room.code);
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
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = getActorId(req);

    if (room.host_id == actorId) {
        if (room.status === 'started') {
            // In-game forfeit — guest wins.
            _finishRoomByForfeit(room, 'host', 'leave', Date.now());
            return res.json({ ok: true, room: roomStore.snapshot(room) });
        }
        // Lobby: host is leaving their own room — delete it silently. No forfeit, no penalty.
        roomStore.delete(room.code);
        return res.json({ ok: true });
    }

    if (room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }

    if (room.status === 'started') {
        // In-game forfeit — host wins.
        _finishRoomByForfeit(room, 'guest', 'leave', Date.now());
        return res.json({ ok: true, room: roomStore.snapshot(room) });
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
    roomStore.touchPresence(room, actorId);
    return res.json({ ok: true, room: roomStore.snapshot(room) });
};

// GET /api/rooms  (debug: list all active rooms)
const listRooms = (req, res) => {
    res.json(roomStore.all());
};

// PATCH /api/rooms/:code/select
// Body: { user_id, character, skills }
const updateSelections = (req, res) => {
    const room = roomStore.get(req.params.code);
    const { character, skills, passive } = req.body;
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);

    // Validate selections
    const validation = validateSelections({ character, skills, passive });
    if (!validation.valid) {
        return res.status(400).json({ message: validation.error });
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
    roomStore.touchPresence(room, actorId); // Fix #14 + presence: refresh idle timer / last seen
    return res.json({ ok: true });
};

// POST /api/rooms/:code/start
const startRoomGame = (req, res) => {
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    const actorId = getActorId(req);
    if (room.host_id != actorId) {
        return res.status(403).json({ message: 'Only host may start the game' });
    }
    if (!room.guest_id) {
        return res.status(409).json({ message: 'Cannot start without guest' });
    }
    // Idempotent start: if already started, return current room state instead of 409.
    // This avoids client-side race errors when duplicate start requests arrive close together.
    if (room.status === 'started') {
        return res.json({ ok: true, already_started: true, room: roomStore.snapshot(room) });
    }

    // Server-side readiness validation (don't rely only on client UI).
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
    roomStore.touchPresence(room, actorId);
    return res.json({ ok: true, room: roomStore.snapshot(room) });
};

// PATCH /api/rooms/:code/phase
// Body: { user_id, phase, round_id? }
// Host is authoritative for phase transitions.
const updatePhase = (req, res) => {
    const { user_id, phase, round_id } = req.body;
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!user_id || !phase) return res.status(400).json({ message: 'user_id and phase required' });
    const phaseValidation = validatePhase(phase);
    if (!phaseValidation.valid) return res.status(400).json({ message: phaseValidation.error });
    if (room.status !== 'started') return res.status(409).json({ message: 'Room not started' });

    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);

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
    roomStore.touchPresence(room, actorId); // Fix #14 + presence: refresh idle timer / last seen
    return res.json({ ok: true, room: roomStore.snapshot(room) });
};

// PATCH /api/rooms/:code/progress
const updateProgress = (req, res) => {
    const { progress, typos, send_mutation, mana } = req.body;
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
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
                const skillValidation = validateChosenSkill(chosen, room.host_skills);
                if (!skillValidation.valid) {
                    return res.status(400).json({ message: skillValidation.error });
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
                const skillValidation = validateChosenSkill(chosen, room.guest_skills);
                if (!skillValidation.valid) {
                    return res.status(400).json({ message: skillValidation.error });
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
        console.log(`[rooms] ${room.code} progress host=${room.host_progress} guest=${room.guest_progress} first_finish_at=${room.first_finish_at} by=${room.first_finish_by}`);
    }
    room.seq = (room.seq || 0) + 1;
    roomStore.touchPresence(room, actorId); // + presence: refresh idle timer / last seen
    // Return the full room snapshot when a phase transition occurred so the client
    // can apply it immediately without waiting for the next poll cycle.
    if (phaseTransitioned) {
        return res.json({ ok: true, room: roomStore.snapshot(room) });
    }
    return res.json({ ok: true });
};

// PATCH /api/rooms/:code/hp
// Body: { user_id, host_hp, guest_hp, host_streak, guest_streak }
// Host is authoritative for HP and streak sync.
const updateHP = (req, res) => {
    const { host_hp, guest_hp, host_streak, guest_streak } = req.body;
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!assertBodyUserMatchesActor(req, res)) return;
    const actorId = getActorId(req);
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
    roomStore.touchPresence(room, actorId); //presence: refresh idle timer / last seen
    _finishRoomFromHp(room, Date.now());
    if (process.env.LOG_ROOMS === 'true') {
        console.log(`[rooms] ${room.code} hp host=${room.host_hp} guest=${room.guest_hp} streaks=${room.host_streak}/${room.guest_streak}`);
    }
    return res.json({ ok: true, room: roomStore.snapshot(room) });
};

// PATCH /api/rooms/:code/rematch - Mark that a player wants to rematch
const updateRematch = (req, res) => {
    const room = roomStore.get(req.params.code);
    if (!room) return res.status(404).json({ message: 'Room not found' });
    
    const actorId = getActorId(req);
    if (room.host_id != actorId && room.guest_id != actorId) {
        return res.status(403).json({ message: 'Not in this room' });
    }
    
    if (!assertBodyUserMatchesActor(req, res)) return;
    
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
        room.host_hp = 0;
        room.host_streak = 0;

        room.guest_character = null;
        room.guest_skills = [];
        room.guest_passive = "";
        room.guest_skill = "";
        room.guest_skill_picked = false;
        room.guest_progress = 0.0;
        room.guest_typos = 0;
        room.guest_mutations = [];
        room.guest_hp = 0;
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
    roomStore.touchPresence(room, actorId);

    return res.json({ ok: true, rematch_ready: !!(room.host_wants_rematch && room.guest_wants_rematch) || room.status === 'lobby', room: roomStore.snapshot(room) });
};

module.exports = {
    createRoom, joinRoom, getRoomStatus, closeRoom, leaveRoom,
    matchmake, leaveQueue, queueStatus, listRooms,
    updateSelections, startRoomGame, updatePhase, updateProgress, updateHP, updateRematch,
    // Shared state for socket handler — same in-memory store, no duplication
    rooms,
    startCleanup,
    _enterTypingPhase,
    _enterSkillSelectPhase,
    _finishRoomByForfeit,
    _finishRoomFromHp,
    roomSnapshot: (room) => roomStore.snapshot(room),
};
