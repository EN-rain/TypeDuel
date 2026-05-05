// In-memory room store
// rooms[code] = { code, host_id, host_name, guest_id, guest_name, created_at }
const rooms = {};

const ROOM_TTL_MS = 10 * 60 * 1000; // rooms expire after 10 minutes

// Cleanup old rooms every minute
setInterval(() => {
    const now = Date.now();
    for (const code in rooms) {
        if (now - rooms[code].created_at > ROOM_TTL_MS) {
            delete rooms[code];
        }
    }
}, 60 * 1000);

// POST /api/rooms/create
// Body: { user_id, display_name, code }
const createRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    // Clean up any existing room hosted by this user
    for (const c in rooms) {
        if (rooms[c].host_id === user_id) delete rooms[c];
    }
    rooms[code] = {
        code,
        seq:            0,
        host_id:        user_id,
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
        guest_progress: 0.0,
        guest_typos:    0,
        guest_mutations:[],
        // Phase sync (authoritative timers)
        phase:          'lobby',      // lobby, skill_select, typing, resolving, finished
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,      // 'host' | 'guest'
        round_id:          0,
        host_hp:           0,
        guest_hp:          0,
        created_at:     Date.now()
    };
    return res.json({ ok: true, code });
};

// POST /api/rooms/join
// Body: { user_id, display_name, code }
const joinRoom = (req, res) => {
    const { user_id, display_name, code } = req.body;
    if (!user_id || !code) {
        return res.status(400).json({ message: 'user_id and code required' });
    }
    const room = rooms[code.toUpperCase()];
    if (!room) {
        return res.status(404).json({ message: 'Room not found' });
    }
    if (room.host_id == user_id) {   // loose == handles string/int mismatch
        return res.status(403).json({ message: 'Cannot join your own room' });
    }
    if (room.guest_id && room.guest_id != user_id) {
        return res.status(409).json({ message: 'Room is full' });
    }
    room.guest_id      = user_id;
    room.guest_name    = display_name || 'Player';
    room.guest_character = null;
    room.guest_skills  = [];
    room.guest_passive = "";
    room.seq = (room.seq || 0) + 1;
    return res.json({ ok: true, room });
};

const roomSnapshot = (room) => ({
    ...room,
    server_now: Date.now()
});

// GET /api/rooms/:code
const getRoomStatus = (req, res) => {
    const code = req.params.code.toUpperCase();
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    return res.json(roomSnapshot(room));
};

// DELETE /api/rooms/:code  (host closes the room)
const closeRoom = (req, res) => {
    const code = req.params.code.toUpperCase();
    delete rooms[code];
    return res.json({ ok: true });
};

const matchmake = (req, res) => {
    const { user_id, display_name } = req.body;
    if (!user_id) return res.status(400).json({ message: 'user_id required' });

    for (const code in rooms) {
        if (!rooms[code].guest_id && rooms[code].host_id !== user_id) {
            rooms[code].guest_id       = user_id;
            rooms[code].guest_name     = display_name || 'Player';
            rooms[code].guest_character = null;
            rooms[code].guest_skills   = [];
            rooms[code].guest_passive  = "";
            return res.json({ ok: true, role: 'guest', room: rooms[code] });
        }
    }

    const code = Math.random().toString(36).substring(2, 8).toUpperCase();
    for (const c in rooms) {
        if (rooms[c].host_id === user_id) delete rooms[c];
    }
    rooms[code] = {
        code,
        seq:             0,
        host_id:         user_id,
        host_name:       display_name || 'Player',
        host_character:  null,
        host_skills:     [],
        host_passive:    "",
        guest_id:        null,
        guest_name:      null,
        guest_character: null,
        guest_skills:    [],
        guest_passive:   "",
        host_progress:   0.0,
        guest_progress:  0.0,
        host_typos:      0,
        guest_typos:     0,
        host_mutations:  [],
        guest_mutations: [],
        phase:           'lobby',
        phase_started_at: 0,
        typing_started_at: 0,
        first_finish_at:   0,
        first_finish_by:   null,
        round_id:          0,
        created_at:      Date.now()
    };
    return res.json({ ok: true, role: 'host', code });
};

// GET /api/rooms  (debug: list all active rooms)
const listRooms = (req, res) => {
    res.json(Object.values(rooms));
};

// PATCH /api/rooms/:code/select
// Body: { user_id, character, skills }
const updateSelections = (req, res) => {
    const code = req.params.code.toUpperCase();
    const { user_id, character, skills, passive } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });

    if (room.host_id == user_id) {
        if (character !== undefined) room.host_character = character;
        if (skills !== undefined)    room.host_skills    = skills;
        if (passive !== undefined)   room.host_passive   = passive;
    } else if (room.guest_id == user_id) {
        if (character !== undefined) room.guest_character = character;
        if (skills !== undefined)    room.guest_skills    = skills;
        if (passive !== undefined)   room.guest_passive   = passive;
    } else {
        return res.status(403).json({ message: 'Not in this room' });
    }
    room.seq = (room.seq || 0) + 1;
    return res.json({ ok: true });
};

// POST /api/rooms/:code/start
const startRoomGame = (req, res) => {
    const code = req.params.code.toUpperCase();
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    room.status = 'started';
    room.started_at = Date.now();

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
    room.host_mutations = [];
    room.guest_mutations = [];
    // HP is set by host client via /hp once the game scene initializes.
    room.host_hp = room.host_hp || 0;
    room.guest_hp = room.guest_hp || 0;
    room.seq = (room.seq || 0) + 1;
    return res.json({ ok: true, room: roomSnapshot(room) });
};

// PATCH /api/rooms/:code/phase
// Body: { user_id, phase, round_id? }
// Host is authoritative for phase transitions.
const updatePhase = (req, res) => {
    const code = req.params.code.toUpperCase();
    const { user_id, phase, round_id } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (!user_id || !phase) return res.status(400).json({ message: 'user_id and phase required' });

    if (room.host_id != user_id) {
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
        room.host_mutations = [];
        room.guest_mutations = [];
    }

    room.seq = (room.seq || 0) + 1;
    return res.json({ ok: true, room: roomSnapshot(room) });
};

// PATCH /api/rooms/:code/progress
const updateProgress = (req, res) => {
    const code = req.params.code.toUpperCase();
    const { user_id, progress, typos, send_mutation } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });

    const progressNum = (progress === undefined) ? undefined : Number(progress);
    const typosNum = (typos === undefined) ? undefined : Number(typos);

    if (room.host_id == user_id) {
        if (progressNum !== undefined && Number.isFinite(progressNum)) room.host_progress = progressNum;
        if (typosNum !== undefined && Number.isFinite(typosNum)) room.host_typos = typosNum;
        if (send_mutation) room.guest_mutations.push(send_mutation);
    } else if (room.guest_id == user_id) {
        if (progressNum !== undefined && Number.isFinite(progressNum)) room.guest_progress = progressNum;
        if (typosNum !== undefined && Number.isFinite(typosNum)) room.guest_typos = typosNum;
        if (send_mutation) room.host_mutations.push(send_mutation);
    }

    // First-finish tracking for authoritative snap timer
    if (!room.first_finish_at && progressNum !== undefined && Number.isFinite(progressNum) && progressNum >= 0.999) {
        room.first_finish_at = Date.now();
        room.first_finish_by = (room.host_id == user_id) ? 'host' : 'guest';
    }
    if (process.env.LOG_ROOMS === 'true' && progressNum !== undefined) {
        console.log(`[rooms] ${code} progress host=${room.host_progress} guest=${room.guest_progress} first_finish_at=${room.first_finish_at} by=${room.first_finish_by}`);
    }
    room.seq = (room.seq || 0) + 1;
    return res.json({ ok: true });
};

// PATCH /api/rooms/:code/hp
// Body: { user_id, host_hp, guest_hp }
// Host is authoritative for HP sync.
const updateHP = (req, res) => {
    const code = req.params.code.toUpperCase();
    const { user_id, host_hp, guest_hp } = req.body;
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    if (room.host_id != user_id) return res.status(403).json({ message: 'Only host may sync hp' });

    const hostHpNum = Number(host_hp);
    const guestHpNum = Number(guest_hp);
    if (!Number.isFinite(hostHpNum) || !Number.isFinite(guestHpNum)) {
        return res.status(400).json({ message: 'host_hp and guest_hp must be numbers' });
    }

    room.host_hp = hostHpNum;
    room.guest_hp = guestHpNum;
    room.seq = (room.seq || 0) + 1;
    if (process.env.LOG_ROOMS === 'true') {
        console.log(`[rooms] ${code} hp host=${room.host_hp} guest=${room.guest_hp}`);
    }
    return res.json({ ok: true, room: roomSnapshot(room) });
};

module.exports = { createRoom, joinRoom, getRoomStatus, closeRoom, matchmake, listRooms, updateSelections, startRoomGame, updatePhase, updateProgress, updateHP };
