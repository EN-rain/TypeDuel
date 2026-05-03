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
        host_id: user_id,
        host_name: display_name || 'Player',
        guest_id: null,
        guest_name: null,
        created_at: Date.now()
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
    if (room.host_id === user_id) {
        return res.status(403).json({ message: 'Cannot join your own room' });
    }
    if (room.guest_id && room.guest_id !== user_id) {
        return res.status(409).json({ message: 'Room is full' });
    }
    room.guest_id   = user_id;
    room.guest_name = display_name || 'Player';
    return res.json({ ok: true, room });
};

// GET /api/rooms/:code
const getRoomStatus = (req, res) => {
    const code = req.params.code.toUpperCase();
    const room = rooms[code];
    if (!room) return res.status(404).json({ message: 'Room not found' });
    return res.json(room);
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
            rooms[code].guest_id = user_id;
            rooms[code].guest_name = display_name || 'Player';
            return res.json({ ok: true, role: 'guest', room: rooms[code] });
        }
    }

    const code = Math.random().toString(36).substring(2, 8).toUpperCase();
    for (const c in rooms) {
        if (rooms[c].host_id === user_id) delete rooms[c];
    }
    rooms[code] = {
        code,
        host_id: user_id,
        host_name: display_name || 'Player',
        guest_id: null,
        guest_name: null,
        created_at: Date.now()
    };
    return res.json({ ok: true, role: 'host', code });
};

module.exports = { createRoom, joinRoom, getRoomStatus, closeRoom, matchmake };